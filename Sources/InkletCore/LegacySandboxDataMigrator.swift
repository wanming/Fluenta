import CoreFoundation
import CryptoKit
import Foundation

public enum LegacyMigrationComponent: String, CaseIterable, Codable, Hashable, Sendable {
    case preferences
    case credentials
    case history
}

public struct LegacyMigrationVersions: Equatable, Sendable {
    public static let preferences = 1
    public static let credentials = 1
    public static let history = 1
}

public enum PreferenceFingerprint: Codable, Equatable, Hashable, Sendable {
    case absent
    case present(sha256: String)
}

public enum LegacyMigrationMode: Equatable, Sendable {
    case automatic
    case userAssisted
}

public enum LegacyMigrationFailureKind: Equatable, Sendable {
    case permissionDenied
    case indeterminateLookup
    case invalidSource
    case readFailed
    case decodeFailed
    case writeFailed
    case keychainFailed
    case lockTimedOut
}

public struct LegacyMigrationFailure: Error, Equatable, Sendable {
    public let component: LegacyMigrationComponent?
    public let kind: LegacyMigrationFailureKind
    public let sourceLabel: String
    public let destinationLabel: String?
    public let nonSensitiveDescription: String

    public init(
        component: LegacyMigrationComponent?,
        kind: LegacyMigrationFailureKind,
        sourceLabel: String,
        destinationLabel: String?,
        nonSensitiveDescription: String
    ) {
        self.component = component
        self.kind = kind
        self.sourceLabel = sourceLabel
        self.destinationLabel = destinationLabel
        self.nonSensitiveDescription = nonSensitiveDescription
    }
}

public enum LegacyMigrationComponentResult: Equatable, Sendable {
    case alreadyComplete(version: Int)
    case completed(changedDestination: Bool)
    case noLegacyData
    case incomplete(LegacyMigrationFailure)
}

public struct LegacySandboxMigrationOutcome: Equatable, Sendable {
    public let results: [LegacyMigrationComponent: LegacyMigrationComponentResult]
    private let mode: LegacyMigrationMode
    private let changedDestinationOverride: Bool

    public init(results: [LegacyMigrationComponent: LegacyMigrationComponentResult]) {
        self.init(results: results, mode: .automatic, changedDestinationOverride: false)
    }

    init(
        results: [LegacyMigrationComponent: LegacyMigrationComponentResult],
        mode: LegacyMigrationMode,
        changedDestinationOverride: Bool = false
    ) {
        self.results = results
        self.mode = mode
        self.changedDestinationOverride = changedDestinationOverride
    }

    public var hasIncompleteComponents: Bool {
        guard LegacyMigrationComponent.allCases.allSatisfy({ results[$0] != nil }) else {
            return true
        }
        return results.values.contains { result in
            guard case .incomplete = result else { return false }
            return true
        }
    }

    public var changedDestination: Bool {
        changedDestinationOverride || results.values.contains { result in
            guard case let .completed(changedDestination) = result else { return false }
            return changedDestination
        }
    }

    public var shouldOfferAssistedImport: Bool {
        guard mode == .automatic else { return false }
        return results.values.contains { result in
            guard case let .incomplete(failure) = result else { return false }
            return failure.kind == .permissionDenied || failure.kind == .indeterminateLookup
        }
    }
}

public protocol LegacyMigrationStateStore: Sendable {
    func reload() throws
    func completedVersion(for component: LegacyMigrationComponent) throws -> Int?
    func setCompletedVersion(_ version: Int, for component: LegacyMigrationComponent) throws
    func preferenceBaseline() throws -> [String: PreferenceFingerprint]?
    func setPreferenceBaseline(_ baseline: [String: PreferenceFingerprint]) throws
}

public enum LegacyMigrationStateStoreError: Error, Equatable {
    case invalidStoredValue
    case encodingFailed
    case decodingFailed
    case synchronizationFailed
    case writeVerificationFailed
}

struct LegacyMigrationExactDomainDefaultsResolver: @unchecked Sendable {
    private final class UserDefaultsReference: @unchecked Sendable {
        let value: UserDefaults

        init(_ value: UserDefaults) {
            self.value = value
        }
    }

    private let currentBundleIdentifier: String?
    private let currentDomainWriterFactory: @Sendable () -> UserDefaults
    private let freshCurrentDomainFactory: @Sendable () -> UserDefaults
    private let suiteFactory: @Sendable (String) -> UserDefaults?

    init(
        currentBundleIdentifier: String?,
        currentDomainWriterFactory: @escaping @Sendable () -> UserDefaults,
        freshCurrentDomainFactory: @escaping @Sendable () -> UserDefaults,
        suiteFactory: @escaping @Sendable (String) -> UserDefaults?
    ) {
        self.currentBundleIdentifier = currentBundleIdentifier
        self.currentDomainWriterFactory = currentDomainWriterFactory
        self.freshCurrentDomainFactory = freshCurrentDomainFactory
        self.suiteFactory = suiteFactory
    }

    static func live(
        currentDomainWriter: UserDefaults = .standard,
        suiteFactory: @escaping @Sendable (String) -> UserDefaults? = {
            UserDefaults(suiteName: $0)
        }
    ) -> LegacyMigrationExactDomainDefaultsResolver {
        let currentDomainWriterReference = UserDefaultsReference(currentDomainWriter)
        return LegacyMigrationExactDomainDefaultsResolver(
            currentBundleIdentifier: Bundle.main.bundleIdentifier,
            currentDomainWriterFactory: { currentDomainWriterReference.value },
            freshCurrentDomainFactory: { UserDefaults() },
            suiteFactory: suiteFactory
        )
    }

    func writerDefaults(for domainName: String) -> UserDefaults? {
        if domainName == currentBundleIdentifier {
            return currentDomainWriterFactory()
        }
        return suiteFactory(domainName)
    }

    func freshDefaults(for domainName: String) -> UserDefaults? {
        if domainName == currentBundleIdentifier {
            return freshCurrentDomainFactory()
        }
        return suiteFactory(domainName)
    }
}

public final class UserDefaultsLegacyMigrationStateStore: LegacyMigrationStateStore, @unchecked Sendable {
    static let preferenceBaselineKey = "Inklet.LegacySandboxMigration.preferenceBaseline.v1"

    private let writerDefaults: UserDefaults?
    private let persistentDomainName: String
    private let exactDomainResolver: LegacyMigrationExactDomainDefaultsResolver

    public convenience init(
        persistentDomainName: String
    ) {
        self.init(
            persistentDomainName: persistentDomainName,
            exactDomainResolver: .live()
        )
    }

    convenience init(
        persistentDomainName: String,
        exactDomainDefaultsFactory: @escaping @Sendable (String) -> UserDefaults?
    ) {
        self.init(
            persistentDomainName: persistentDomainName,
            exactDomainResolver: .live(suiteFactory: exactDomainDefaultsFactory)
        )
    }

    init(
        persistentDomainName: String,
        exactDomainResolver: LegacyMigrationExactDomainDefaultsResolver
    ) {
        precondition(!persistentDomainName.isEmpty, "A persistent defaults domain is required.")
        self.writerDefaults = exactDomainResolver.writerDefaults(for: persistentDomainName)
        self.persistentDomainName = persistentDomainName
        self.exactDomainResolver = exactDomainResolver
    }

    public func reload() throws {
        _ = try freshlySynchronizedDomain()
    }

    public func completedVersion(for component: LegacyMigrationComponent) throws -> Int? {
        try completedVersion(for: component, in: freshlySynchronizedDomain())
    }

    public func setCompletedVersion(
        _ version: Int,
        for component: LegacyMigrationComponent
    ) throws {
        guard let writerDefaults else {
            throw LegacyMigrationStateStoreError.synchronizationFailed
        }
        let key = Self.completedVersionKey(for: component)
        let previousValue = try freshlySynchronizedDomain()[key]
        writerDefaults.set(version, forKey: key)

        do {
            guard writerDefaults.synchronize() else {
                throw LegacyMigrationStateStoreError.synchronizationFailed
            }
            let verificationDomain = try freshlySynchronizedDomain()
            guard try completedVersion(for: component, in: verificationDomain) == version else {
                throw LegacyMigrationStateStoreError.writeVerificationFailed
            }
        } catch {
            let writeError = error
            try restore(previousValue, forKey: key)
            throw writeError
        }
    }

    public func preferenceBaseline() throws -> [String: PreferenceFingerprint]? {
        try preferenceBaseline(in: freshlySynchronizedDomain())
    }

    private func preferenceBaseline(
        in persistentDomain: [String: Any]
    ) throws -> [String: PreferenceFingerprint]? {
        guard let storedValue = persistentDomain[Self.preferenceBaselineKey] else {
            return nil
        }
        guard let data = storedValue as? Data else {
            throw LegacyMigrationStateStoreError.invalidStoredValue
        }
        do {
            let baseline = try JSONDecoder().decode(
                [String: PreferenceFingerprint].self,
                from: data
            )
            guard Self.containsOnlyValidDigests(baseline) else {
                throw LegacyMigrationStateStoreError.invalidStoredValue
            }
            return baseline
        } catch let error as LegacyMigrationStateStoreError {
            throw error
        } catch {
            throw LegacyMigrationStateStoreError.decodingFailed
        }
    }

    public func setPreferenceBaseline(
        _ baseline: [String: PreferenceFingerprint]
    ) throws {
        guard let writerDefaults else {
            throw LegacyMigrationStateStoreError.synchronizationFailed
        }
        guard Self.containsOnlyValidDigests(baseline) else {
            throw LegacyMigrationStateStoreError.invalidStoredValue
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(baseline)
        } catch {
            throw LegacyMigrationStateStoreError.encodingFailed
        }

        let previousValue = try freshlySynchronizedDomain()[Self.preferenceBaselineKey]
        writerDefaults.set(data, forKey: Self.preferenceBaselineKey)

        do {
            guard writerDefaults.synchronize() else {
                throw LegacyMigrationStateStoreError.synchronizationFailed
            }
            let verificationDomain = try freshlySynchronizedDomain()
            guard try preferenceBaseline(in: verificationDomain) == baseline else {
                throw LegacyMigrationStateStoreError.writeVerificationFailed
            }
        } catch {
            let writeError = error
            try restore(previousValue, forKey: Self.preferenceBaselineKey)
            throw writeError
        }
    }

    static func completedVersionKey(for component: LegacyMigrationComponent) -> String {
        switch component {
        case .preferences:
            return "Inklet.LegacySandboxMigration.preferencesVersion"
        case .credentials:
            return "Inklet.LegacySandboxMigration.credentialsVersion"
        case .history:
            return "Inklet.LegacySandboxMigration.historyVersion"
        }
    }

    private static func containsOnlyValidDigests(
        _ baseline: [String: PreferenceFingerprint]
    ) -> Bool {
        baseline.values.allSatisfy { fingerprint in
            guard case let .present(sha256) = fingerprint else { return true }
            let bytes = sha256.utf8
            return bytes.count == 64 && bytes.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            }
        }
    }

    private func completedVersion(
        for component: LegacyMigrationComponent,
        in persistentDomain: [String: Any]
    ) throws -> Int? {
        let key = Self.completedVersionKey(for: component)
        guard let storedValue = persistentDomain[key] else { return nil }
        guard let number = storedValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number),
              let version = storedValue as? Int else {
            throw LegacyMigrationStateStoreError.invalidStoredValue
        }
        return version
    }

    private func freshlySynchronizedDomain() throws -> [String: Any] {
        guard let refreshedDefaults = exactDomainResolver.freshDefaults(for: persistentDomainName),
              refreshedDefaults.synchronize() else {
            throw LegacyMigrationStateStoreError.synchronizationFailed
        }
        return refreshedDefaults.persistentDomain(forName: persistentDomainName) ?? [:]
    }

    private func restore(_ previousValue: Any?, forKey key: String) throws {
        guard let writerDefaults else {
            throw LegacyMigrationStateStoreError.synchronizationFailed
        }
        if let previousValue {
            writerDefaults.set(previousValue, forKey: key)
        } else {
            writerDefaults.removeObject(forKey: key)
        }
        guard writerDefaults.synchronize() else {
            throw LegacyMigrationStateStoreError.synchronizationFailed
        }
        let verificationDomain = try freshlySynchronizedDomain()
        guard Self.storedValuesAreEqual(
            verificationDomain[key],
            previousValue
        ) else {
            throw LegacyMigrationStateStoreError.writeVerificationFailed
        }
    }

    private static func storedValuesAreEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs as NSObject, rhs as NSObject):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }
}

enum LegacyPreferenceFingerprintError: Error, Equatable {
    case unsupportedType
}

enum LegacyPreferenceFingerprinter {
    static func fingerprint(of value: Any?) throws -> PreferenceFingerprint {
        guard let value else { return .absent }
        let bytes = try canonicalData(for: value)
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return .present(sha256: digest)
    }

    private enum TypeTag: UInt8 {
        case boolean = 1
        case integer = 2
        case real = 3
        case data = 4
        case date = 5
        case string = 6
        case array = 7
        case dictionary = 8
    }

    private static func canonicalData(for value: Any) throws -> Data {
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
           let boolean = value as? Bool {
            return framed(tag: .boolean, payload: Data([boolean ? 1 : 0]))
        }

        if let number = value as? NSNumber {
            if CFNumberIsFloatType(number) {
                var bitPattern = number.doubleValue.bitPattern.bigEndian
                let payload = withUnsafeBytes(of: &bitPattern) { Data($0) }
                return framed(tag: .real, payload: payload)
            }
            return framed(tag: .integer, payload: Data(number.stringValue.utf8))
        }

        if let data = value as? Data {
            return framed(tag: .data, payload: data)
        }

        if let date = value as? Date {
            var bitPattern = date.timeIntervalSinceReferenceDate.bitPattern.bigEndian
            let payload = withUnsafeBytes(of: &bitPattern) { Data($0) }
            return framed(tag: .date, payload: payload)
        }

        if let string = value as? String {
            return framed(tag: .string, payload: Data(string.utf8))
        }

        if let array = value as? [Any] {
            var payload = Data()
            append(UInt64(array.count), to: &payload)
            for element in array {
                payload.append(try canonicalData(for: element))
            }
            return framed(tag: .array, payload: payload)
        }

        if let dictionary = value as? [String: Any] {
            var payload = Data()
            let sortedKeys = dictionary.keys.sorted()
            append(UInt64(sortedKeys.count), to: &payload)
            for key in sortedKeys {
                payload.append(try canonicalData(for: key))
                guard let nestedValue = dictionary[key] else {
                    throw LegacyPreferenceFingerprintError.unsupportedType
                }
                payload.append(try canonicalData(for: nestedValue))
            }
            return framed(tag: .dictionary, payload: payload)
        }

        throw LegacyPreferenceFingerprintError.unsupportedType
    }

    private static func framed(tag: TypeTag, payload: Data) -> Data {
        var data = Data([tag.rawValue])
        append(UInt64(payload.count), to: &data)
        data.append(payload)
        return data
    }

    private static func append(_ integer: UInt64, to data: inout Data) {
        var bigEndianInteger = integer.bigEndian
        withUnsafeBytes(of: &bigEndianInteger) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

public final class LegacySandboxDataMigrator: @unchecked Sendable {
    private let bundleIdentifier: String
    private let storagePaths: InkletStoragePaths
    private let homeDirectoryURL: URL
    private let preferenceDefaults: UserDefaults?
    private let exactDomainResolver: LegacyMigrationExactDomainDefaultsResolver
    private let fileSystem: any LegacyMigrationFileSystem
    private let stateStore: any LegacyMigrationStateStore
    private let keychainStore: @Sendable (String) -> KeychainStore
    private let lock: LegacyMigrationLock

    public convenience init(
        bundleIdentifier: String,
        storagePaths: InkletStoragePaths,
        homeDirectoryURL: URL,
        defaults: UserDefaults,
        exactDomainDefaultsFactory: @escaping @Sendable (String) -> UserDefaults? = {
            UserDefaults(suiteName: $0)
        },
        fileSystem: any LegacyMigrationFileSystem,
        stateStore: any LegacyMigrationStateStore,
        keychainStore: @escaping @Sendable (String) -> KeychainStore,
        lock: LegacyMigrationLock
    ) {
        self.init(
            bundleIdentifier: bundleIdentifier,
            storagePaths: storagePaths,
            homeDirectoryURL: homeDirectoryURL,
            exactDomainResolver: .live(
                currentDomainWriter: defaults,
                suiteFactory: exactDomainDefaultsFactory
            ),
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainStore: keychainStore,
            lock: lock
        )
    }

    init(
        bundleIdentifier: String,
        storagePaths: InkletStoragePaths,
        homeDirectoryURL: URL,
        exactDomainResolver: LegacyMigrationExactDomainDefaultsResolver,
        fileSystem: any LegacyMigrationFileSystem,
        stateStore: any LegacyMigrationStateStore,
        keychainStore: @escaping @Sendable (String) -> KeychainStore,
        lock: LegacyMigrationLock
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.storagePaths = storagePaths
        self.homeDirectoryURL = homeDirectoryURL
        self.preferenceDefaults = exactDomainResolver.writerDefaults(for: bundleIdentifier)
        self.exactDomainResolver = exactDomainResolver
        self.fileSystem = fileSystem
        self.stateStore = stateStore
        self.keychainStore = keychainStore
        self.lock = lock
    }

    public static func live(
        storagePaths: InkletStoragePaths,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> LegacySandboxDataMigrator {
        let keychainService = LocalAPIKeyStore.resolvedKeychainService(
            bundleIdentifier: storagePaths.bundleIdentifier
        )
        let exactDomainResolver = LegacyMigrationExactDomainDefaultsResolver.live(
            currentDomainWriter: defaults
        )
        return LegacySandboxDataMigrator(
            bundleIdentifier: storagePaths.bundleIdentifier,
            storagePaths: storagePaths,
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser,
            exactDomainResolver: exactDomainResolver,
            fileSystem: FileManagerLegacyMigrationFileSystem(fileManager: fileManager),
            stateStore: UserDefaultsLegacyMigrationStateStore(
                persistentDomainName: storagePaths.bundleIdentifier,
                exactDomainResolver: exactDomainResolver
            ),
            keychainStore: { providerID in
                KeychainStore(service: keychainService, account: providerID)
            },
            lock: LegacyMigrationLock(fileURL: storagePaths.migrationLockFileURL)
        )
    }

    public func migrateAutomatically() -> LegacySandboxMigrationOutcome {
        migrate(rootURL: expectedLegacyRoot, mode: .automatic)
    }

    public func migrateUserSelectedData(
        at selectedDataRootURL: URL
    ) -> LegacySandboxMigrationOutcome {
        migrate(rootURL: selectedDataRootURL, mode: .userAssisted)
    }

    public func validateUserSelectedDataRoot(_ selectedURL: URL) throws -> URL {
        let selectedStandardURL = selectedURL.standardizedFileURL
        let expectedStandardURL = expectedLegacyRoot.standardizedFileURL
        let selectedCanonicalURL = try canonicalURL(
            for: selectedStandardURL,
            sourceLabel: Self.containerSourceLabel
        )

        guard selectedCanonicalURL == selectedStandardURL else {
            throw invalidSourceFailure(sourceLabel: Self.containerSourceLabel)
        }

        let expectedCanonicalURL = try canonicalURL(
            for: expectedStandardURL,
            sourceLabel: Self.containerSourceLabel
        )
        guard selectedCanonicalURL == expectedCanonicalURL else {
            throw invalidSourceFailure(sourceLabel: Self.containerSourceLabel)
        }

        try validateSelectedSource(
            at: selectedCanonicalURL,
            expectedKind: .directory,
            sourceLabel: Self.containerSourceLabel
        )

        let preferencesURL = legacyPreferencesURL(rootURL: selectedCanonicalURL)
        try validateSelectedSource(
            at: preferencesURL,
            expectedKind: .regularFile,
            sourceLabel: preferencesSourceLabel
        )

        return selectedCanonicalURL
    }

    public static func expectedLegacyDataRoot(
        bundleIdentifier: String,
        homeDirectoryURL: URL
    ) -> URL {
        homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    private static let containerSourceLabel = "legacy/container"

    private var expectedLegacyRoot: URL {
        Self.expectedLegacyDataRoot(
            bundleIdentifier: bundleIdentifier,
            homeDirectoryURL: homeDirectoryURL
        )
    }

    private var preferencesSourceLabel: String {
        "legacy/Library/Preferences/\(bundleIdentifier).plist"
    }

    private static let historySourceLabel = "legacy/Library/Application Support/Inklet/history.jsonl"

    private func migrate(
        rootURL: URL,
        mode: LegacyMigrationMode
    ) -> LegacySandboxMigrationOutcome {
        do {
            return try lock.withLock {
                try stateStore.reload()
                var results = try completedResults()
                let initiallyIncompleteComponents = LegacyMigrationComponent.allCases.filter {
                    results[$0] == nil
                }
                guard !initiallyIncompleteComponents.isEmpty else {
                    return LegacySandboxMigrationOutcome(results: results, mode: mode)
                }

                var changedDestination = false
                var preferenceBaseline: [String: PreferenceFingerprint]?
                if initiallyIncompleteComponents.contains(.preferences) {
                    do {
                        preferenceBaseline = try ensurePreferenceBaseline(mode: mode)
                    } catch let failure as LegacyMigrationFailure {
                        results[.preferences] = .incomplete(failure)
                    } catch {
                        results[.preferences] = .incomplete(
                            baselineFailure()
                        )
                    }
                }

                let pendingComponents = initiallyIncompleteComponents.filter {
                    results[$0] == nil
                }
                guard !pendingComponents.isEmpty else {
                    return LegacySandboxMigrationOutcome(
                        results: results,
                        mode: mode,
                        changedDestinationOverride: changedDestination
                    )
                }

                do {
                    let validatedRootURL: URL
                    if mode == .userAssisted {
                        validatedRootURL = try validateUserSelectedDataRoot(rootURL)
                    } else {
                        validatedRootURL = rootURL.standardizedFileURL
                    }

                    try migrateSources(
                        at: validatedRootURL,
                        incompleteComponents: pendingComponents,
                        preferenceBaseline: preferenceBaseline,
                        results: &results,
                        changedDestination: &changedDestination
                    )
                } catch let failure as LegacyMigrationFailure {
                    setFailures(
                        for: pendingComponents,
                        kind: failure.kind,
                        sourceLabel: failure.sourceLabel,
                        results: &results,
                        description: failure.nonSensitiveDescription
                    )
                }
                return LegacySandboxMigrationOutcome(
                    results: results,
                    mode: mode,
                    changedDestinationOverride: changedDestination
                )
            }
        } catch LegacyMigrationLockError.timedOut {
            return lockTimeoutOutcome(mode: mode)
        } catch let failure as LegacyMigrationFailure {
            return failureOutcome(from: failure, mode: mode)
        } catch {
            return failureOutcome(kind: .writeFailed, mode: mode)
        }
    }

    private func completedResults() throws -> [
        LegacyMigrationComponent: LegacyMigrationComponentResult
    ] {
        var results: [LegacyMigrationComponent: LegacyMigrationComponentResult] = [:]
        for component in LegacyMigrationComponent.allCases {
            if let version = try stateStore.completedVersion(for: component),
               version >= currentVersion(for: component) {
                results[component] = .alreadyComplete(version: version)
            }
        }
        return results
    }

    private func migrateSources(
        at rootURL: URL,
        incompleteComponents: [LegacyMigrationComponent],
        preferenceBaseline: [String: PreferenceFingerprint]?,
        results: inout [LegacyMigrationComponent: LegacyMigrationComponentResult],
        changedDestination: inout Bool
    ) throws {
        switch try inspectedSource(at: rootURL, expectedKind: .directory) {
        case .missing:
            completeNoLegacyData(incompleteComponents, results: &results)
            return
        case let .failure(kind):
            setFailures(
                for: incompleteComponents,
                kind: kind,
                sourceLabel: Self.containerSourceLabel,
                results: &results
            )
            return
        case .present:
            break
        }

        let preferenceComponents = [
            LegacyMigrationComponent.preferences,
            .credentials,
        ].filter { incompleteComponents.contains($0) }
        if !preferenceComponents.isEmpty {
            processLegacyPreferencesFile(
                at: legacyPreferencesURL(rootURL: rootURL),
                components: preferenceComponents,
                preferenceBaseline: preferenceBaseline,
                results: &results,
                changedDestination: &changedDestination
            )
        }

        if incompleteComponents.contains(.history) {
            processLegacyHistoryFile(
                at: legacyHistoryURL(rootURL: rootURL),
                results: &results,
                changedDestination: &changedDestination
            )
        }
    }

    private func processLegacyPreferencesFile(
        at sourceURL: URL,
        components: [LegacyMigrationComponent],
        preferenceBaseline: [String: PreferenceFingerprint]?,
        results: inout [LegacyMigrationComponent: LegacyMigrationComponentResult],
        changedDestination: inout Bool
    ) {
        do {
            switch try inspectedSource(at: sourceURL, expectedKind: .regularFile) {
            case .missing:
                completeNoLegacyData(components, results: &results)
                return
            case let .failure(kind):
                setFailures(
                    for: components,
                    kind: kind,
                    sourceLabel: preferencesSourceLabel,
                    results: &results
                )
                return
            case .present:
                break
            }

            let sourceData: Data
            do {
                sourceData = try fileSystem.readData(at: sourceURL)
            } catch {
                let kind = sourceReadFailureKind(error)
                setFailures(
                    for: components,
                    kind: kind,
                    sourceLabel: preferencesSourceLabel,
                    results: &results
                )
                return
            }

            let propertyList: [String: Any]
            do {
                guard let decoded = try PropertyListSerialization.propertyList(
                    from: sourceData,
                    options: [],
                    format: nil
                ) as? [String: Any] else {
                    throw LegacyPreferenceValidationError.invalidValue
                }
                propertyList = decoded
            } catch {
                setFailures(
                    for: components,
                    kind: .decodeFailed,
                    sourceLabel: preferencesSourceLabel,
                    results: &results
                )
                return
            }

            if components.contains(.preferences) {
                if let preferenceBaseline {
                    processPreferences(
                        propertyList,
                        baseline: preferenceBaseline,
                        results: &results,
                        changedDestination: &changedDestination
                    )
                } else {
                    results[.preferences] = .incomplete(baselineFailure())
                }
            }
            if components.contains(.credentials) {
                processCredentials(
                    propertyList,
                    results: &results,
                    changedDestination: &changedDestination
                )
            }
        } catch {
            setFailures(
                for: components,
                kind: .indeterminateLookup,
                sourceLabel: preferencesSourceLabel,
                results: &results
            )
        }
    }

    private func processLegacyHistoryFile(
        at sourceURL: URL,
        results: inout [LegacyMigrationComponent: LegacyMigrationComponentResult],
        changedDestination: inout Bool
    ) {
        do {
            switch try inspectedSource(at: sourceURL, expectedKind: .regularFile) {
            case .missing:
                completeNoLegacyData([.history], results: &results)
                return
            case let .failure(kind):
                setFailures(
                    for: [.history],
                    kind: kind,
                    sourceLabel: Self.historySourceLabel,
                    results: &results
                )
                return
            case .present:
                break
            }

            let legacyData: Data
            do {
                legacyData = try fileSystem.readData(at: sourceURL)
            } catch {
                results[.history] = .incomplete(
                    failure(
                        component: .history,
                        kind: sourceReadFailureKind(error),
                        sourceLabel: Self.historySourceLabel,
                        description: nonSensitiveDescription(for: sourceReadFailureKind(error))
                    )
                )
                return
            }

            processHistory(
                legacyData,
                results: &results,
                changedDestination: &changedDestination
            )
        } catch {
            results[.history] = .incomplete(
                failure(
                    component: .history,
                    kind: .indeterminateLookup,
                    sourceLabel: Self.historySourceLabel,
                    description: nonSensitiveDescription(for: .indeterminateLookup)
                )
            )
        }
    }

    private enum LegacyPreferenceValidationError: Error {
        case invalidValue
    }

    private var preferenceBaselineAttemptGuardURL: URL {
        storagePaths.applicationSupportRootURL.appendingPathComponent(
            "legacy-migration.preference-baseline-attempted"
        )
    }

    private enum PreferenceBaselineAttemptGuardState {
        case newAttempt
        case attempted
        case verified
    }

    private var preferenceBaselineAttemptedGuardData: Data {
        Data("Inklet legacy preference baseline attempted v1\n\(bundleIdentifier)\n".utf8)
    }

    private var preferenceBaselineVerifiedGuardData: Data {
        Data("Inklet legacy preference baseline verified v1\n\(bundleIdentifier)\n".utf8)
    }

    private func ensurePreferenceBaseline(
        mode: LegacyMigrationMode
    ) throws -> [String: PreferenceFingerprint] {
        let guardState = try ensurePreferenceBaselineAttemptGuard()

        let storedBaseline: [String: PreferenceFingerprint]?
        do {
            storedBaseline = try stateStore.preferenceBaseline()
        } catch {
            throw baselineFailure()
        }

        if guardState == .verified {
            guard let storedBaseline,
                  hasExactPreferenceBaselineKeys(storedBaseline) else {
                throw baselineFailure()
            }
            return storedBaseline
        }

        if let storedBaseline {
            guard hasExactPreferenceBaselineKeys(storedBaseline) else {
                throw baselineFailure()
            }
            try markPreferenceBaselineGuardVerified()
            return storedBaseline
        }

        guard guardState == .newAttempt else {
            throw baselineFailure()
        }

        guard mode == .automatic else { throw baselineFailure() }

        let persistentDomain: [String: Any]
        do {
            persistentDomain = try freshPersistentDomain()
        } catch {
            throw baselineFailure()
        }

        var baseline: [String: PreferenceFingerprint] = [:]
        do {
            for key in InkletPreferenceKeys.recognizedLegacyKeys {
                baseline[key] = try LegacyPreferenceFingerprinter.fingerprint(
                    of: persistentDomain[key]
                )
            }
        } catch {
            throw baselineFailure()
        }

        do {
            try stateStore.setPreferenceBaseline(baseline)
            guard try stateStore.preferenceBaseline() == baseline else {
                throw LegacyMigrationStateStoreError.writeVerificationFailed
            }
        } catch {
            throw baselineFailure()
        }
        try markPreferenceBaselineGuardVerified()
        return baseline
    }

    private func ensurePreferenceBaselineAttemptGuard() throws
        -> PreferenceBaselineAttemptGuardState {
        let guardURL = preferenceBaselineAttemptGuardURL.standardizedFileURL
        let isMissing: Bool
        do {
            let kind = try fileSystem.itemKind(at: guardURL)
            guard kind == .regularFile else { throw baselineFailure() }
            isMissing = false
        } catch let failure as LegacyMigrationFailure {
            throw failure
        } catch {
            switch LegacyMigrationLookupErrorClassifier.classify(error) {
            case .missing:
                isMissing = true
            case .permissionDenied, .indeterminateLookup:
                throw baselineFailure()
            }
        }

        if isMissing {
            do {
                try fileSystem.createDirectory(at: storagePaths.applicationSupportRootURL)
                try fileSystem.writeDataAtomically(
                    preferenceBaselineAttemptedGuardData,
                    to: guardURL
                )
            } catch {
                throw baselineFailure()
            }
            try verifyPreferenceBaselineGuardData(preferenceBaselineAttemptedGuardData)
            return .newAttempt
        }

        let storedData: Data
        do {
            guard try fileSystem.itemKind(at: guardURL) == .regularFile else {
                throw baselineFailure()
            }
            storedData = try fileSystem.readData(at: guardURL)
        } catch let failure as LegacyMigrationFailure {
            throw failure
        } catch {
            throw baselineFailure()
        }
        if storedData == preferenceBaselineVerifiedGuardData {
            return .verified
        }
        if storedData == preferenceBaselineAttemptedGuardData {
            return .attempted
        }
        throw baselineFailure()
    }

    private func markPreferenceBaselineGuardVerified() throws {
        do {
            try fileSystem.writeDataAtomically(
                preferenceBaselineVerifiedGuardData,
                to: preferenceBaselineAttemptGuardURL
            )
            try verifyPreferenceBaselineGuardData(preferenceBaselineVerifiedGuardData)
        } catch let failure as LegacyMigrationFailure {
            throw failure
        } catch {
            throw baselineFailure()
        }
    }

    private func verifyPreferenceBaselineGuardData(_ expectedData: Data) throws {
        do {
            guard try fileSystem.itemKind(at: preferenceBaselineAttemptGuardURL) == .regularFile,
                  try fileSystem.readData(at: preferenceBaselineAttemptGuardURL) == expectedData else {
                throw baselineFailure()
            }
        } catch let failure as LegacyMigrationFailure {
            throw failure
        } catch {
            throw baselineFailure()
        }
    }

    private func hasExactPreferenceBaselineKeys(
        _ baseline: [String: PreferenceFingerprint]
    ) -> Bool {
        Set(baseline.keys) == Set(InkletPreferenceKeys.recognizedLegacyKeys)
    }

    private func baselineFailure() -> LegacyMigrationFailure {
        failure(
            component: .preferences,
            kind: .writeFailed,
            sourceLabel: preferencesSourceLabel,
            description: "Preference migration safety state could not be verified."
        )
    }

    private func freshPersistentDomain() throws -> [String: Any] {
        guard let freshDefaults = exactDomainResolver.freshDefaults(for: bundleIdentifier),
              freshDefaults.synchronize() else {
            throw LegacyMigrationStateStoreError.synchronizationFailed
        }
        return freshDefaults.persistentDomain(forName: bundleIdentifier) ?? [:]
    }

    private func processPreferences(
        _ propertyList: [String: Any],
        baseline: [String: PreferenceFingerprint],
        results: inout [LegacyMigrationComponent: LegacyMigrationComponentResult],
        changedDestination: inout Bool
    ) {
        let legacyValues: [String: Any]
        do {
            legacyValues = try validatedLegacyPreferenceValues(in: propertyList)
        } catch {
            results[.preferences] = .incomplete(
                failure(
                    component: .preferences,
                    kind: .decodeFailed,
                    sourceLabel: preferencesSourceLabel,
                    description: nonSensitiveDescription(for: .decodeFailed)
                )
            )
            return
        }

        guard hasExactPreferenceBaselineKeys(baseline) else {
            results[.preferences] = .incomplete(baselineFailure())
            return
        }

        guard let preferenceDefaults else {
            results[.preferences] = .incomplete(preferenceWriteFailure())
            return
        }

        let currentDomain: [String: Any]
        do {
            currentDomain = try freshPersistentDomain()
        } catch {
            results[.preferences] = .incomplete(
                preferenceWriteFailure()
            )
            return
        }

        var expectedWrites: [String: PreferenceFingerprint] = [:]
        var didChange = false
        do {
            for key in InkletPreferenceKeys.recognizedLegacyKeys {
                guard let legacyValue = legacyValues[key] else { continue }
                let currentFingerprint = try LegacyPreferenceFingerprinter.fingerprint(
                    of: currentDomain[key]
                )
                guard currentFingerprint == baseline[key] else { continue }
                let legacyFingerprint = try LegacyPreferenceFingerprinter.fingerprint(
                    of: legacyValue
                )
                guard currentFingerprint != legacyFingerprint else { continue }
                preferenceDefaults.set(legacyValue, forKey: key)
                expectedWrites[key] = legacyFingerprint
                didChange = true
            }
        } catch {
            results[.preferences] = .incomplete(preferenceWriteFailure())
            return
        }

        if didChange {
            changedDestination = true
            guard preferenceDefaults.synchronize() else {
                results[.preferences] = .incomplete(preferenceWriteFailure())
                return
            }

            do {
                let verificationDomain = try freshPersistentDomain()
                for (key, expectedFingerprint) in expectedWrites {
                    guard try LegacyPreferenceFingerprinter.fingerprint(
                        of: verificationDomain[key]
                    ) == expectedFingerprint else {
                        throw LegacyMigrationStateStoreError.writeVerificationFailed
                    }
                }
            } catch {
                results[.preferences] = .incomplete(preferenceWriteFailure())
                return
            }
        }

        finishComponent(
            .preferences,
            changed: didChange,
            sourceLabel: preferencesSourceLabel,
            results: &results,
            changedDestination: &changedDestination
        )
    }

    private func validatedLegacyPreferenceValues(
        in propertyList: [String: Any]
    ) throws -> [String: Any] {
        var values: [String: Any] = [:]
        for key in InkletPreferenceKeys.recognizedLegacyKeys {
            guard let value = propertyList[key] else { continue }
            switch key {
            case InkletPreferenceKeys.appConfig,
                 InkletPreferenceKeys.modelCatalogSnapshot:
                guard value is Data else {
                    throw LegacyPreferenceValidationError.invalidValue
                }
                values[key] = value
            case InkletPreferenceKeys.interfaceLanguage,
                 InkletPreferenceKeys.lastWritingPromptModeID:
                guard value is String else {
                    throw LegacyPreferenceValidationError.invalidValue
                }
                values[key] = value
            case InkletPreferenceKeys.didCompleteOnboarding:
                guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
                      value is Bool else {
                    throw LegacyPreferenceValidationError.invalidValue
                }
                values[key] = value
            case InkletPreferenceKeys.translationPanelSize:
                guard let dictionary = value as? [String: Any] else {
                    throw LegacyPreferenceValidationError.invalidValue
                }
                var numericDictionary: [String: NSNumber] = [:]
                for (dimension, rawNumber) in dictionary {
                    guard let number = rawNumber as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID() else {
                        throw LegacyPreferenceValidationError.invalidValue
                    }
                    numericDictionary[dimension] = number
                }
                values[key] = numericDictionary
            default:
                throw LegacyPreferenceValidationError.invalidValue
            }
        }
        return values
    }

    private func processCredentials(
        _ propertyList: [String: Any],
        results: inout [LegacyMigrationComponent: LegacyMigrationComponentResult],
        changedDestination: inout Bool
    ) {
        let entries: [(providerID: String, apiKey: String)]
        do {
            entries = try propertyList.compactMap { key, value in
                guard let providerID = InkletPreferenceKeys.providerID(
                    fromLegacyKey: key
                ) else {
                    return nil
                }
                guard let apiKey = value as? String else {
                    throw LegacyPreferenceValidationError.invalidValue
                }
                return (providerID, apiKey)
            }.sorted { $0.providerID < $1.providerID }
        } catch {
            results[.credentials] = .incomplete(
                failure(
                    component: .credentials,
                    kind: .decodeFailed,
                    sourceLabel: preferencesSourceLabel,
                    description: nonSensitiveDescription(for: .decodeFailed)
                )
            )
            return
        }

        var didChange = false
        for entry in entries {
            do {
                let store = keychainStore(entry.providerID)
                if try store.loadAPIKey() == nil {
                    if try store.insertAPIKeyIfAbsent(entry.apiKey) {
                        didChange = true
                        changedDestination = true
                    }
                }
            } catch {
                results[.credentials] = .incomplete(
                    failure(
                        component: .credentials,
                        kind: .keychainFailed,
                        sourceLabel: preferencesSourceLabel,
                        description: nonSensitiveDescription(for: .keychainFailed)
                    )
                )
                return
            }
        }

        finishComponent(
            .credentials,
            changed: didChange,
            sourceLabel: preferencesSourceLabel,
            results: &results,
            changedDestination: &changedDestination
        )
    }

    private func processHistory(
        _ legacyData: Data,
        results: inout [LegacyMigrationComponent: LegacyMigrationComponentResult],
        changedDestination: inout Bool
    ) {
        let destinationData: Data
        do {
            destinationData = try readDestinationHistoryData()
        } catch let migrationFailure as LegacyMigrationFailure {
            results[.history] = .incomplete(migrationFailure)
            return
        } catch {
            results[.history] = .incomplete(historyReadFailure())
            return
        }

        var itemsByID: [UUID: HistoryItem] = [:]
        for item in HistoryJSONLCodec.decodeValidItems(from: legacyData) {
            itemsByID[item.id] = item
        }
        for item in HistoryJSONLCodec.decodeValidItems(from: destinationData) {
            itemsByID[item.id] = item
        }
        let mergedItems = itemsByID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let mergedData: Data
        do {
            mergedData = try HistoryJSONLCodec.encode(mergedItems)
        } catch {
            results[.history] = .incomplete(historyWriteFailure())
            return
        }

        var didChange = false
        if mergedData != destinationData {
            do {
                try fileSystem.createDirectory(
                    at: storagePaths.historyFileURL.deletingLastPathComponent()
                )
                try fileSystem.writeDataAtomically(
                    mergedData,
                    to: storagePaths.historyFileURL
                )
                didChange = true
                changedDestination = true
            } catch {
                if let writeError = error as? LegacyMigrationAtomicWriteError,
                   writeError.destinationWasReplaced {
                    changedDestination = true
                }
                results[.history] = .incomplete(historyWriteFailure())
                return
            }
        }

        finishComponent(
            .history,
            changed: didChange,
            sourceLabel: Self.historySourceLabel,
            results: &results,
            changedDestination: &changedDestination
        )
    }

    private func readDestinationHistoryData() throws -> Data {
        let destinationURL = storagePaths.historyFileURL.standardizedFileURL
        do {
            let kind = try fileSystem.itemKind(at: destinationURL)
            guard kind == .regularFile else {
                throw failure(
                    component: .history,
                    kind: .invalidSource,
                    sourceLabel: Self.historySourceLabel,
                    description: nonSensitiveDescription(for: .invalidSource)
                )
            }
        } catch let migrationFailure as LegacyMigrationFailure {
            throw migrationFailure
        } catch {
            switch LegacyMigrationLookupErrorClassifier.classify(error) {
            case .missing:
                return Data()
            case .permissionDenied, .indeterminateLookup:
                throw historyReadFailure()
            }
        }

        do {
            return try fileSystem.readData(at: destinationURL)
        } catch {
            throw historyReadFailure()
        }
    }

    private func finishComponent(
        _ component: LegacyMigrationComponent,
        changed: Bool,
        sourceLabel: String,
        results: inout [LegacyMigrationComponent: LegacyMigrationComponentResult],
        changedDestination: inout Bool
    ) {
        if changed {
            changedDestination = true
        }
        do {
            try stateStore.setCompletedVersion(
                currentVersion(for: component),
                for: component
            )
            results[component] = .completed(changedDestination: changed)
        } catch {
            results[component] = .incomplete(
                failure(
                    component: component,
                    kind: .writeFailed,
                    sourceLabel: sourceLabel,
                    description: nonSensitiveDescription(for: .writeFailed)
                )
            )
        }
    }

    private func preferenceWriteFailure() -> LegacyMigrationFailure {
        failure(
            component: .preferences,
            kind: .writeFailed,
            sourceLabel: preferencesSourceLabel,
            description: nonSensitiveDescription(for: .writeFailed)
        )
    }

    private func historyReadFailure() -> LegacyMigrationFailure {
        failure(
            component: .history,
            kind: .readFailed,
            sourceLabel: Self.historySourceLabel,
            description: nonSensitiveDescription(for: .readFailed)
        )
    }

    private func historyWriteFailure() -> LegacyMigrationFailure {
        failure(
            component: .history,
            kind: .writeFailed,
            sourceLabel: Self.historySourceLabel,
            description: nonSensitiveDescription(for: .writeFailed)
        )
    }

    private func sourceReadFailureKind(_ error: Error) -> LegacyMigrationFailureKind {
        switch LegacyMigrationLookupErrorClassifier.classify(error) {
        case .permissionDenied:
            return .permissionDenied
        case .missing, .indeterminateLookup:
            return .readFailed
        }
    }

    private func completeNoLegacyData(
        _ components: [LegacyMigrationComponent],
        results: inout [LegacyMigrationComponent: LegacyMigrationComponentResult]
    ) {
        for component in components {
            do {
                try stateStore.setCompletedVersion(
                    currentVersion(for: component),
                    for: component
                )
                results[component] = .noLegacyData
            } catch {
                results[component] = .incomplete(
                    failure(
                        component: component,
                        kind: .writeFailed,
                        sourceLabel: Self.containerSourceLabel,
                        description: "Migration completion state could not be verified."
                    )
                )
            }
        }
    }

    private func setFailures(
        for components: [LegacyMigrationComponent],
        kind: LegacyMigrationFailureKind,
        sourceLabel: String,
        results: inout [LegacyMigrationComponent: LegacyMigrationComponentResult],
        description: String? = nil
    ) {
        for component in components {
            results[component] = .incomplete(
                failure(
                    component: component,
                    kind: kind,
                    sourceLabel: sourceLabel,
                    description: description ?? nonSensitiveDescription(for: kind)
                )
            )
        }
    }

    private enum SourceInspection: Equatable {
        case missing
        case present
        case failure(LegacyMigrationFailureKind)
    }

    private func inspectedSource(
        at sourceURL: URL,
        expectedKind: LegacyMigrationItemKind
    ) throws -> SourceInspection {
        let standardizedURL = sourceURL.standardizedFileURL
        do {
            let itemKind = try fileSystem.itemKind(at: standardizedURL)
            guard itemKind == expectedKind else { return .failure(.invalidSource) }
            let canonicalURL = try fileSystem.canonicalURL(for: standardizedURL)
                .standardizedFileURL
            guard canonicalURL == standardizedURL else { return .failure(.invalidSource) }
            return .present
        } catch {
            switch LegacyMigrationLookupErrorClassifier.classify(error) {
            case .missing:
                return .missing
            case .permissionDenied:
                return .failure(.permissionDenied)
            case .indeterminateLookup:
                return .failure(.indeterminateLookup)
            }
        }
    }

    private func canonicalURL(for url: URL, sourceLabel: String) throws -> URL {
        do {
            return try fileSystem.canonicalURL(for: url).standardizedFileURL
        } catch {
            let kind: LegacyMigrationFailureKind
            switch LegacyMigrationLookupErrorClassifier.classify(error) {
            case .missing:
                kind = .invalidSource
            case .permissionDenied:
                kind = .permissionDenied
            case .indeterminateLookup:
                kind = .indeterminateLookup
            }
            throw failure(
                component: nil,
                kind: kind,
                sourceLabel: sourceLabel,
                description: nonSensitiveDescription(for: kind)
            )
        }
    }

    private func validateSelectedSource(
        at sourceURL: URL,
        expectedKind: LegacyMigrationItemKind,
        sourceLabel: String
    ) throws {
        switch try inspectedSource(at: sourceURL, expectedKind: expectedKind) {
        case .present:
            return
        case .missing, .failure(.invalidSource):
            throw invalidSourceFailure(sourceLabel: sourceLabel)
        case let .failure(kind):
            throw failure(
                component: nil,
                kind: kind,
                sourceLabel: sourceLabel,
                description: nonSensitiveDescription(for: kind)
            )
        }
    }

    private func invalidSourceFailure(sourceLabel: String) -> LegacyMigrationFailure {
        failure(
            component: nil,
            kind: .invalidSource,
            sourceLabel: sourceLabel,
            description: nonSensitiveDescription(for: .invalidSource)
        )
    }

    private func failureOutcome(
        from originalFailure: LegacyMigrationFailure,
        mode: LegacyMigrationMode
    ) -> LegacySandboxMigrationOutcome {
        var results: [LegacyMigrationComponent: LegacyMigrationComponentResult] = [:]
        for component in LegacyMigrationComponent.allCases {
            results[component] = .incomplete(
                failure(
                    component: component,
                    kind: originalFailure.kind,
                    sourceLabel: originalFailure.sourceLabel,
                    description: originalFailure.nonSensitiveDescription
                )
            )
        }
        return LegacySandboxMigrationOutcome(results: results, mode: mode)
    }

    private func failureOutcome(
        kind: LegacyMigrationFailureKind,
        mode: LegacyMigrationMode
    ) -> LegacySandboxMigrationOutcome {
        var results: [LegacyMigrationComponent: LegacyMigrationComponentResult] = [:]
        for component in LegacyMigrationComponent.allCases {
            results[component] = .incomplete(
                failure(
                    component: component,
                    kind: kind,
                    sourceLabel: Self.containerSourceLabel,
                    description: nonSensitiveDescription(for: kind)
                )
            )
        }
        return LegacySandboxMigrationOutcome(results: results, mode: mode)
    }

    private func lockTimeoutOutcome(
        mode: LegacyMigrationMode
    ) -> LegacySandboxMigrationOutcome {
        var results: [LegacyMigrationComponent: LegacyMigrationComponentResult] = [:]
        do {
            try stateStore.reload()
            for component in LegacyMigrationComponent.allCases {
                do {
                    if let version = try stateStore.completedVersion(for: component),
                       version >= currentVersion(for: component) {
                        results[component] = .alreadyComplete(version: version)
                    }
                } catch {
                    // This component remains fail-closed when its persisted marker is unreadable.
                }
            }
        } catch {
            // No marker is trusted when persistent state could not be refreshed.
        }

        let incompleteComponents = LegacyMigrationComponent.allCases.filter {
            results[$0] == nil
        }
        setFailures(
            for: incompleteComponents,
            kind: .lockTimedOut,
            sourceLabel: Self.containerSourceLabel,
            results: &results
        )
        return LegacySandboxMigrationOutcome(results: results, mode: mode)
    }

    private func failure(
        component: LegacyMigrationComponent?,
        kind: LegacyMigrationFailureKind,
        sourceLabel: String,
        description: String
    ) -> LegacyMigrationFailure {
        LegacyMigrationFailure(
            component: component,
            kind: kind,
            sourceLabel: sourceLabel,
            destinationLabel: component.map(destinationLabel(for:)),
            nonSensitiveDescription: description
        )
    }

    private func destinationLabel(for component: LegacyMigrationComponent) -> String {
        switch component {
        case .preferences:
            return "destination/preferences"
        case .credentials:
            return "destination/Keychain"
        case .history:
            return "destination/history.jsonl"
        }
    }

    private func currentVersion(for component: LegacyMigrationComponent) -> Int {
        switch component {
        case .preferences:
            return LegacyMigrationVersions.preferences
        case .credentials:
            return LegacyMigrationVersions.credentials
        case .history:
            return LegacyMigrationVersions.history
        }
    }

    private func legacyPreferencesURL(rootURL: URL) -> URL {
        rootURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    private func legacyHistoryURL(rootURL: URL) -> URL {
        rootURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Inklet", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    private func nonSensitiveDescription(for kind: LegacyMigrationFailureKind) -> String {
        switch kind {
        case .permissionDenied:
            return "Access to the legacy source was denied."
        case .indeterminateLookup:
            return "The legacy source could not be checked safely."
        case .invalidSource:
            return "The legacy source does not match the expected item."
        case .readFailed:
            return "The legacy source could not be read safely."
        case .decodeFailed:
            return "The legacy source could not be decoded safely."
        case .writeFailed:
            return "Migration completion state could not be verified."
        case .keychainFailed:
            return "The destination credential could not be updated safely."
        case .lockTimedOut:
            return "Another migration operation is still in progress."
        }
    }
}

private enum LegacyMigrationLookupDisposition {
    case missing
    case permissionDenied
    case indeterminateLookup
}

private enum LegacyMigrationLookupErrorClassifier {
    static func classify(_ error: Error) -> LegacyMigrationLookupDisposition {
        let rootError = error as NSError
        let errors = underlyingErrors(startingWith: rootError)
        if errors.contains(where: isPermissionDenied) {
            return .permissionDenied
        }
        if isConfirmedMissing(rootError) {
            return .missing
        }
        if isRecognizedCocoaMissing(rootError),
           errors.dropFirst().contains(where: isConfirmedMissing) {
            return .missing
        }
        return .indeterminateLookup
    }

    private static func underlyingErrors(startingWith error: NSError) -> [NSError] {
        var errors: [NSError] = []
        var nextError: NSError? = error
        var remainingDepth = 8

        while let currentError = nextError, remainingDepth > 0 {
            errors.append(currentError)
            nextError = currentError.userInfo[NSUnderlyingErrorKey] as? NSError
            remainingDepth -= 1
        }
        return errors
    }

    private static func isConfirmedMissing(_ error: NSError) -> Bool {
        error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    private static func isRecognizedCocoaMissing(_ error: NSError) -> Bool {
        guard error.domain == NSCocoaErrorDomain else { return false }
        return error.code == NSFileNoSuchFileError
            || error.code == NSFileReadNoSuchFileError
    }

    private static func isPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(EACCES) || error.code == Int(EPERM)
        }
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError
    }
}
