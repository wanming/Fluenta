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

    public init(results: [LegacyMigrationComponent: LegacyMigrationComponentResult]) {
        self.init(results: results, mode: .automatic)
    }

    init(
        results: [LegacyMigrationComponent: LegacyMigrationComponentResult],
        mode: LegacyMigrationMode
    ) {
        self.results = results
        self.mode = mode
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
        results.values.contains { result in
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

public final class UserDefaultsLegacyMigrationStateStore: LegacyMigrationStateStore, @unchecked Sendable {
    static let preferenceBaselineKey = "Inklet.LegacySandboxMigration.preferenceBaseline.v1"

    private let writerDefaults: UserDefaults
    private let persistentDomainName: String
    private let exactDomainDefaultsFactory: @Sendable (String) -> UserDefaults?

    public convenience init(
        persistentDomainName: String
    ) {
        self.init(
            persistentDomainName: persistentDomainName,
            exactDomainDefaultsFactory: { UserDefaults(suiteName: $0) }
        )
    }

    init(
        persistentDomainName: String,
        exactDomainDefaultsFactory: @escaping @Sendable (String) -> UserDefaults?
    ) {
        precondition(!persistentDomainName.isEmpty, "A persistent defaults domain is required.")
        guard let writerDefaults = exactDomainDefaultsFactory(persistentDomainName) else {
            preconditionFailure("The persistent defaults domain could not be opened.")
        }
        self.writerDefaults = writerDefaults
        self.persistentDomainName = persistentDomainName
        self.exactDomainDefaultsFactory = exactDomainDefaultsFactory
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
        guard let refreshedDefaults = exactDomainDefaultsFactory(persistentDomainName),
              refreshedDefaults.synchronize() else {
            throw LegacyMigrationStateStoreError.synchronizationFailed
        }
        return refreshedDefaults.persistentDomain(forName: persistentDomainName) ?? [:]
    }

    private func restore(_ previousValue: Any?, forKey key: String) throws {
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
    private let defaults: UserDefaults
    private let fileSystem: any LegacyMigrationFileSystem
    private let stateStore: any LegacyMigrationStateStore
    private let keychainStore: @Sendable (String) -> KeychainStore
    private let lock: LegacyMigrationLock

    public init(
        bundleIdentifier: String,
        storagePaths: InkletStoragePaths,
        homeDirectoryURL: URL,
        defaults: UserDefaults,
        fileSystem: any LegacyMigrationFileSystem,
        stateStore: any LegacyMigrationStateStore,
        keychainStore: @escaping @Sendable (String) -> KeychainStore,
        lock: LegacyMigrationLock
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.storagePaths = storagePaths
        self.homeDirectoryURL = homeDirectoryURL
        self.defaults = defaults
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
        return LegacySandboxDataMigrator(
            bundleIdentifier: storagePaths.bundleIdentifier,
            storagePaths: storagePaths,
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser,
            defaults: defaults,
            fileSystem: FileManagerLegacyMigrationFileSystem(fileManager: fileManager),
            stateStore: UserDefaultsLegacyMigrationStateStore(
                persistentDomainName: storagePaths.bundleIdentifier
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
                let incompleteComponents = LegacyMigrationComponent.allCases.filter {
                    results[$0] == nil
                }
                guard !incompleteComponents.isEmpty else {
                    return LegacySandboxMigrationOutcome(results: results, mode: mode)
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
                        incompleteComponents: incompleteComponents,
                        results: &results
                    )
                } catch let failure as LegacyMigrationFailure {
                    setFailures(
                        for: incompleteComponents,
                        kind: failure.kind,
                        sourceLabel: failure.sourceLabel,
                        results: &results,
                        description: failure.nonSensitiveDescription
                    )
                }
                return LegacySandboxMigrationOutcome(results: results, mode: mode)
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
        results: inout [LegacyMigrationComponent: LegacyMigrationComponentResult]
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
            processDiscoveredSource(
                at: legacyPreferencesURL(rootURL: rootURL),
                sourceLabel: preferencesSourceLabel,
                components: preferenceComponents,
                results: &results
            )
        }

        if incompleteComponents.contains(.history) {
            processDiscoveredSource(
                at: legacyHistoryURL(rootURL: rootURL),
                sourceLabel: Self.historySourceLabel,
                components: [.history],
                results: &results
            )
        }
    }

    private func processDiscoveredSource(
        at sourceURL: URL,
        sourceLabel: String,
        components: [LegacyMigrationComponent],
        results: inout [LegacyMigrationComponent: LegacyMigrationComponentResult]
    ) {
        do {
            switch try inspectedSource(at: sourceURL, expectedKind: .regularFile) {
            case .missing:
                completeNoLegacyData(components, results: &results)
            case let .failure(kind):
                setFailures(
                    for: components,
                    kind: kind,
                    sourceLabel: sourceLabel,
                    results: &results
                )
            case .present:
                setFailures(
                    for: components,
                    kind: .readFailed,
                    sourceLabel: sourceLabel,
                    results: &results,
                    description: "The legacy source is present and awaits migration."
                )
            }
        } catch {
            setFailures(
                for: components,
                kind: .indeterminateLookup,
                sourceLabel: sourceLabel,
                results: &results
            )
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
