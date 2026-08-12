import Darwin
import Foundation
import Security
import XCTest
@testable import InkletCore

final class LegacySandboxDataMigratorTests: XCTestCase {
    private let bundleIdentifier = "com.example.inklet"

    func testExpectedLegacyDataRootUsesExactContainerDataPath() {
        let homeDirectory = URL(fileURLWithPath: "/Users/example")

        let result = LegacySandboxDataMigrator.expectedLegacyDataRoot(
            bundleIdentifier: bundleIdentifier,
            homeDirectoryURL: homeDirectory
        )

        XCTAssertEqual(
            result.path,
            "/Users/example/Library/Containers/com.example.inklet/Data"
        )
    }

    func testMissingContainerCompletesEveryComponentAtVersionOne() {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fileSystem.failItemKind(
            at: fixture.legacyRoot,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        )

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(stateStore.reloadCount, 1)
        XCTAssertEqual(stateStore.versions[.preferences], LegacyMigrationVersions.preferences)
        XCTAssertEqual(stateStore.versions[.credentials], LegacyMigrationVersions.credentials)
        XCTAssertEqual(stateStore.versions[.history], LegacyMigrationVersions.history)
        for component in LegacyMigrationComponent.allCases {
            XCTAssertEqual(outcome.results[component], .noLegacyData)
        }
        XCTAssertFalse(outcome.hasIncompleteComponents)
        XCTAssertFalse(outcome.changedDestination)
        XCTAssertFalse(outcome.shouldOfferAssistedImport)
    }

    func testMissingExactSourcesCompleteOnlyTheirRelevantComponents() {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fileSystem.setItemKind(.directory, at: fixture.legacyRoot)
        fileSystem.failItemKind(
            at: fixture.preferencesURL,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        )
        fileSystem.failItemKind(
            at: fixture.historyURL,
            with: NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadNoSuchFileError,
                userInfo: [
                    NSUnderlyingErrorKey: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(ENOENT)
                    )
                ]
            )
        )

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.preferences], .noLegacyData)
        XCTAssertEqual(outcome.results[.credentials], .noLegacyData)
        XCTAssertEqual(outcome.results[.history], .noLegacyData)
        XCTAssertEqual(stateStore.versions[.preferences], 1)
        XCTAssertEqual(stateStore.versions[.credentials], 1)
        XCTAssertEqual(stateStore.versions[.history], 1)
        XCTAssertTrue(fileSystem.itemKindURLs.contains(fixture.legacyRoot))
        XCTAssertTrue(fileSystem.itemKindURLs.contains(fixture.preferencesURL))
        XCTAssertTrue(fileSystem.itemKindURLs.contains(fixture.historyURL))
        XCTAssertEqual(
            fileSystem.readDataURLs,
            [fixture.preferenceAttemptGuardURL, fixture.preferenceAttemptGuardURL]
        )
        XCTAssertFalse(
            fileSystem.allURLs.contains { $0.lastPathComponent == "selection-translation-cache.json" }
        )
    }

    func testPermissionAndIndeterminateSourceErrorsStayIncompleteWithoutMarkers() {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fileSystem.setItemKind(.directory, at: fixture.legacyRoot)
        fileSystem.failItemKind(
            at: fixture.preferencesURL,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        )
        fileSystem.failItemKind(
            at: fixture.historyURL,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        )

        let outcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(outcome.results[.preferences], kind: .permissionDenied)
        assertIncomplete(outcome.results[.credentials], kind: .permissionDenied)
        assertIncomplete(outcome.results[.history], kind: .indeterminateLookup)
        XCTAssertTrue(stateStore.versions.isEmpty)
        XCTAssertTrue(outcome.hasIncompleteComponents)
        XCTAssertTrue(outcome.shouldOfferAssistedImport)
    }

    func testReloadedCompletedMarkersSkipAllSourceProbes() {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        stateStore.versions = [
            .preferences: LegacyMigrationVersions.preferences,
            .credentials: LegacyMigrationVersions.credentials,
            .history: LegacyMigrationVersions.history,
        ]
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(stateStore.reloadCount, 1)
        XCTAssertEqual(outcome.results[.preferences], .alreadyComplete(version: 1))
        XCTAssertEqual(outcome.results[.credentials], .alreadyComplete(version: 1))
        XCTAssertEqual(outcome.results[.history], .alreadyComplete(version: 1))
        XCTAssertTrue(fileSystem.allURLs.isEmpty)
    }

    func testUserSelectionFailurePreservesReloadedCompletedMarkers() {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        stateStore.versions[.preferences] = LegacyMigrationVersions.preferences
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fileSystem.setItemKind(.directory, at: fixture.legacyRoot)
        fileSystem.setItemKind(.symbolicLink, at: fixture.preferencesURL)

        let outcome = fixture.migrator.migrateUserSelectedData(at: fixture.legacyRoot)

        XCTAssertEqual(outcome.results[.preferences], .alreadyComplete(version: 1))
        assertIncomplete(outcome.results[.credentials], kind: .invalidSource)
        assertIncomplete(outcome.results[.history], kind: .invalidSource)
        XCTAssertFalse(outcome.shouldOfferAssistedImport)
    }

    func testLockTimeoutReloadsAndPreservesPersistedMarkersWithoutWrites() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        stateStore.versions[.preferences] = LegacyMigrationVersions.preferences
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore,
            lockTimeout: .milliseconds(5)
        )
        try FileManager.default.createDirectory(
            at: fixture.lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor: Int32 = fixture.lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR, mode_t(0o600))
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(stateStore.reloadCount, 1)
        XCTAssertEqual(stateStore.versions, [.preferences: LegacyMigrationVersions.preferences])
        XCTAssertEqual(outcome.results[.preferences], .alreadyComplete(version: 1))
        assertIncomplete(outcome.results[.credentials], kind: .lockTimedOut)
        assertIncomplete(outcome.results[.history], kind: .lockTimedOut)
        XCTAssertTrue(fileSystem.allURLs.isEmpty)
    }

    func testOutcomeFlagsChangedDestinationAndOnlyRetryableAutomaticFailures() {
        let permissionFailure = LegacyMigrationFailure(
            component: .preferences,
            kind: .permissionDenied,
            sourceLabel: "legacy/preferences",
            destinationLabel: "destination/preferences",
            nonSensitiveDescription: "Permission is required."
        )
        let invalidFailure = LegacyMigrationFailure(
            component: .history,
            kind: .invalidSource,
            sourceLabel: "legacy/history",
            destinationLabel: "destination/history.jsonl",
            nonSensitiveDescription: "The source is invalid."
        )
        let retryable = LegacySandboxMigrationOutcome(results: [
            .preferences: .incomplete(permissionFailure),
            .credentials: .completed(changedDestination: true),
            .history: .noLegacyData,
        ])
        let invalid = LegacySandboxMigrationOutcome(results: [
            .preferences: .noLegacyData,
            .credentials: .alreadyComplete(version: 1),
            .history: .incomplete(invalidFailure),
        ])

        XCTAssertTrue(retryable.hasIncompleteComponents)
        XCTAssertTrue(retryable.changedDestination)
        XCTAssertTrue(retryable.shouldOfferAssistedImport)
        XCTAssertTrue(invalid.hasIncompleteComponents)
        XCTAssertFalse(invalid.changedDestination)
        XCTAssertFalse(invalid.shouldOfferAssistedImport)
    }

    func testOutcomeTreatsEmptyAndPartialResultMapsAsIncomplete() {
        let incompleteOutcomes = [
            LegacySandboxMigrationOutcome(results: [:]),
            LegacySandboxMigrationOutcome(results: [
                .preferences: .noLegacyData,
            ]),
        ]
        let completeOutcome = LegacySandboxMigrationOutcome(results: [
            .preferences: .noLegacyData,
            .credentials: .alreadyComplete(version: 1),
            .history: .completed(changedDestination: false),
        ])

        for outcome in incompleteOutcomes {
            XCTAssertTrue(outcome.hasIncompleteComponents)
        }
        XCTAssertFalse(completeOutcome.hasIncompleteComponents)
    }

    func testPreferenceFingerprintsDistinguishSupportedScalarTypesAndAbsence() throws {
        let fingerprints = try [
            LegacyPreferenceFingerprinter.fingerprint(of: nil),
            LegacyPreferenceFingerprinter.fingerprint(of: true),
            LegacyPreferenceFingerprinter.fingerprint(of: 1),
            LegacyPreferenceFingerprinter.fingerprint(of: 1.0),
            LegacyPreferenceFingerprinter.fingerprint(of: Data([0x01])),
            LegacyPreferenceFingerprinter.fingerprint(of: Date(timeIntervalSinceReferenceDate: 1)),
            LegacyPreferenceFingerprinter.fingerprint(of: "1"),
        ]

        XCTAssertEqual(fingerprints[0], .absent)
        XCTAssertEqual(Set(fingerprints).count, fingerprints.count)
        for fingerprint in fingerprints.dropFirst() {
            guard case let .present(sha256) = fingerprint else {
                return XCTFail("Expected a present fingerprint")
            }
            XCTAssertEqual(sha256.count, 64)
            XCTAssertNotNil(sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        }
    }

    func testPreferenceFingerprintIntegerBoundariesRemainDistinct() throws {
        let fingerprints = try [
            Int64.min as Any,
            Int64.max as Any,
            UInt64.max as Any,
        ].map { try LegacyPreferenceFingerprinter.fingerprint(of: $0) }

        XCTAssertEqual(Set(fingerprints).count, fingerprints.count)
    }

    func testPreferenceFingerprintDistinguishesSignedZeroAndNormalizesNaNPayloads() throws {
        let positiveZero = try LegacyPreferenceFingerprinter.fingerprint(of: 0.0)
        let negativeZero = try LegacyPreferenceFingerprinter.fingerprint(of: -0.0)
        let firstNaN = Double(bitPattern: 0x7ff8_0000_0000_0001)
        let secondNaN = Double(bitPattern: 0x7ff8_0000_0000_0002)

        XCTAssertNotEqual(positiveZero, negativeZero)
        XCTAssertTrue(firstNaN.isNaN)
        XCTAssertTrue(secondNaN.isNaN)
        // NSNumber normalizes NaN payloads; preserving Swift-only bits would break plist bridging.
        XCTAssertEqual(
            try LegacyPreferenceFingerprinter.fingerprint(of: firstNaN),
            try LegacyPreferenceFingerprinter.fingerprint(of: secondNaN)
        )
    }

    func testPreferenceFingerprintBridgedCollectionsMatchSwiftCollections() throws {
        let swiftArray: [Any] = [true, Int64.min, "value"]
        let bridgedArray = NSArray(array: swiftArray)
        let swiftDictionary: [String: Any] = [
            "array": swiftArray,
            "nested": ["key": UInt64.max],
        ]
        let bridgedDictionary = NSDictionary(dictionary: swiftDictionary)

        XCTAssertEqual(
            try LegacyPreferenceFingerprinter.fingerprint(of: swiftArray),
            try LegacyPreferenceFingerprinter.fingerprint(of: bridgedArray)
        )
        XCTAssertEqual(
            try LegacyPreferenceFingerprinter.fingerprint(of: swiftDictionary),
            try LegacyPreferenceFingerprinter.fingerprint(of: bridgedDictionary)
        )
    }

    func testPreferenceFingerprintRejectsUnsupportedNestedBridgedValues() {
        let unsupportedCollections: [Any] = [
            NSArray(array: ["supported", NSNull()]),
            NSDictionary(dictionary: [
                "nested": NSArray(array: [NSNull()]),
            ]),
        ]

        for collection in unsupportedCollections {
            XCTAssertThrowsError(
                try LegacyPreferenceFingerprinter.fingerprint(of: collection)
            ) { error in
                XCTAssertEqual(error as? LegacyPreferenceFingerprintError, .unsupportedType)
            }
        }
    }

    func testPreferenceFingerprintArraysPreserveOrder() throws {
        let first = try LegacyPreferenceFingerprinter.fingerprint(of: ["first", "second"])
        let reordered = try LegacyPreferenceFingerprinter.fingerprint(of: ["second", "first"])

        XCTAssertNotEqual(first, reordered)
    }

    func testPreferenceFingerprintDictionariesCanonicalizeKeysRecursively() throws {
        let first: [String: Any] = [
            "z": ["nestedB": 2, "nestedA": [true, "value"]],
            "a": Data([1, 2, 3]),
        ]
        let sameDifferentInsertionOrder = Dictionary(
            uniqueKeysWithValues: [
                ("a", Data([1, 2, 3]) as Any),
                ("z", ["nestedA": [true, "value"], "nestedB": 2] as Any),
            ]
        )
        let changedNestedType: [String: Any] = [
            "a": Data([1, 2, 3]),
            "z": ["nestedA": [1, "value"], "nestedB": 2],
        ]
        let changedNestedOrder: [String: Any] = [
            "a": Data([1, 2, 3]),
            "z": ["nestedA": ["value", true], "nestedB": 2],
        ]

        let canonical = try LegacyPreferenceFingerprinter.fingerprint(of: first)

        XCTAssertEqual(
            canonical,
            try LegacyPreferenceFingerprinter.fingerprint(of: sameDifferentInsertionOrder)
        )
        XCTAssertNotEqual(
            canonical,
            try LegacyPreferenceFingerprinter.fingerprint(of: changedNestedType)
        )
        XCTAssertNotEqual(
            canonical,
            try LegacyPreferenceFingerprinter.fingerprint(of: changedNestedOrder)
        )
    }

    func testPreferenceFingerprintRejectsUnsupportedValuesWithTypedError() {
        XCTAssertThrowsError(
            try LegacyPreferenceFingerprinter.fingerprint(
                of: URL(fileURLWithPath: "/private/value")
            )
        ) { error in
            XCTAssertEqual(error as? LegacyPreferenceFingerprintError, .unsupportedType)
        }
    }

    func testStateStoreUsesExactKeysAndPersistsOnlyDigestBaseline() throws {
        let suiteName = "LegacyMigrationStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: suiteName
        )
        let plaintext = "known-plaintext-setting-value"
        let fingerprint = try LegacyPreferenceFingerprinter.fingerprint(of: plaintext)
        guard case let .present(digest) = fingerprint else {
            return XCTFail("Expected a digest")
        }

        XCTAssertEqual(
            UserDefaultsLegacyMigrationStateStore.completedVersionKey(for: .preferences),
            "Inklet.LegacySandboxMigration.preferencesVersion"
        )
        XCTAssertEqual(
            UserDefaultsLegacyMigrationStateStore.completedVersionKey(for: .credentials),
            "Inklet.LegacySandboxMigration.credentialsVersion"
        )
        XCTAssertEqual(
            UserDefaultsLegacyMigrationStateStore.completedVersionKey(for: .history),
            "Inklet.LegacySandboxMigration.historyVersion"
        )
        XCTAssertEqual(
            UserDefaultsLegacyMigrationStateStore.preferenceBaselineKey,
            "Inklet.LegacySandboxMigration.preferenceBaseline.v1"
        )

        XCTAssertNil(try store.completedVersion(for: .preferences))
        try store.setCompletedVersion(1, for: .preferences)
        XCTAssertEqual(try store.completedVersion(for: .preferences), 1)
        XCTAssertEqual(
            try runDefaultsCommand([
                "read",
                suiteName,
                "Inklet.LegacySandboxMigration.preferencesVersion",
            ]).trimmingCharacters(in: .whitespacesAndNewlines),
            "1"
        )
        let persistedDomain = try XCTUnwrap(
            defaults.persistentDomain(forName: suiteName)
        )
        XCTAssertEqual(
            persistedDomain["Inklet.LegacySandboxMigration.preferencesVersion"] as? Int,
            1
        )

        try store.setPreferenceBaseline(["setting": fingerprint])
        let storedData = try XCTUnwrap(
            defaults.persistentDomain(forName: suiteName)?[
                "Inklet.LegacySandboxMigration.preferenceBaseline.v1"
            ] as? Data
        )
        let serialization = String(decoding: storedData, as: UTF8.self)
        XCTAssertTrue(serialization.contains(digest))
        XCTAssertFalse(serialization.contains(plaintext))
        XCTAssertEqual(try store.preferenceBaseline(), ["setting": fingerprint])

        let freshStore = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: suiteName
        )
        try freshStore.reload()
        XCTAssertEqual(try freshStore.completedVersion(for: .preferences), 1)
        XCTAssertEqual(try freshStore.preferenceBaseline(), ["setting": fingerprint])
    }

    func testCurrentBundleExactDomainUsesCurrentWriterAndFreshReadersWithoutSuiteFactory() throws {
        let domainName = "LegacyMigrationCurrentDomainTests.\(UUID().uuidString)"
        let writerDefaults = try XCTUnwrap(UserDefaults(suiteName: domainName))
        let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LegacyMigrationCurrentDomain-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let destinationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LegacyMigrationCurrentDomain-destination-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            writerDefaults.removePersistentDomain(forName: domainName)
            try? FileManager.default.removeItem(at: homeDirectory)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let defaultsFactories = LegacyMigrationDefaultsResolverRecorder(
            domainName: domainName,
            writerDefaults: writerDefaults
        )
        let resolver = LegacyMigrationExactDomainDefaultsResolver(
            currentBundleIdentifier: domainName,
            currentDomainWriterFactory: { defaultsFactories.currentWriter() },
            freshCurrentDomainFactory: { defaultsFactories.freshCurrent() },
            suiteFactory: { defaultsFactories.suite(named: $0) }
        )
        let stateStore = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: domainName,
            exactDomainResolver: resolver
        )
        let storagePaths = InkletStoragePaths(
            bundleIdentifier: domainName,
            applicationSupportRootURL: destinationRoot,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        let legacyRoot = LegacySandboxDataMigrator.expectedLegacyDataRoot(
            bundleIdentifier: domainName,
            homeDirectoryURL: homeDirectory
        )
        let preferencesURL = legacyRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(domainName).plist")
        let fileSystem = MigrationTestFileSystem()
        fileSystem.setItemKind(.directory, at: legacyRoot)
        try fileSystem.setPropertyList(
            [InkletPreferenceKeys.interfaceLanguage: "legacy-language"],
            at: preferencesURL
        )
        let keychainClient = MigrationTestKeychainClient()
        let keychainFactory = MigrationTestKeychainFactory(client: keychainClient)
        let migrator = LegacySandboxDataMigrator(
            bundleIdentifier: domainName,
            storagePaths: storagePaths,
            homeDirectoryURL: homeDirectory,
            exactDomainResolver: resolver,
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainStore: { providerID in
                keychainFactory.makeStore(providerID: providerID)
            },
            lock: LegacyMigrationLock(
                fileURL: storagePaths.migrationLockFileURL,
                timeout: .milliseconds(100),
                retryInterval: .milliseconds(1)
            )
        )

        let outcome = migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.preferences], .completed(changedDestination: true))
        let exactDomain = try XCTUnwrap(
            writerDefaults.persistentDomain(forName: domainName)
        )
        XCTAssertEqual(
            exactDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "legacy-language"
        )
        XCTAssertEqual(
            exactDomain[
                UserDefaultsLegacyMigrationStateStore.completedVersionKey(for: .preferences)
            ] as? Int,
            1
        )
        XCTAssertNotNil(
            exactDomain[UserDefaultsLegacyMigrationStateStore.preferenceBaselineKey] as? Data
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(stateStore.preferenceBaseline()).keys),
            Set(InkletPreferenceKeys.recognizedLegacyKeys)
        )
        XCTAssertEqual(defaultsFactories.currentWriterCount, 2)
        XCTAssertGreaterThan(defaultsFactories.freshCurrentCount, 0)
        XCTAssertEqual(defaultsFactories.suiteCount, 0)
    }

    func testNoncurrentExactDomainUsesSuiteFactoryForWriterAndFreshReaders() throws {
        let domainName = "LegacyMigrationNoncurrentDomainTests.\(UUID().uuidString)"
        let writerDefaults = try XCTUnwrap(UserDefaults(suiteName: domainName))
        defer { writerDefaults.removePersistentDomain(forName: domainName) }
        let defaultsFactories = LegacyMigrationDefaultsResolverRecorder(
            domainName: domainName,
            writerDefaults: writerDefaults
        )
        let resolver = LegacyMigrationExactDomainDefaultsResolver(
            currentBundleIdentifier: "com.example.some-other-bundle",
            currentDomainWriterFactory: { defaultsFactories.currentWriter() },
            freshCurrentDomainFactory: { defaultsFactories.freshCurrent() },
            suiteFactory: { defaultsFactories.suite(named: $0) }
        )
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: domainName,
            exactDomainResolver: resolver
        )
        let baseline: [String: PreferenceFingerprint] = ["setting": .absent]

        try store.setCompletedVersion(1, for: .history)
        try store.setPreferenceBaseline(baseline)

        XCTAssertEqual(try store.completedVersion(for: .history), 1)
        XCTAssertEqual(try store.preferenceBaseline(), baseline)
        XCTAssertEqual(defaultsFactories.currentWriterCount, 0)
        XCTAssertEqual(defaultsFactories.freshCurrentCount, 0)
        XCTAssertGreaterThan(defaultsFactories.suiteCount, 0)
    }

    func testNoncurrentFullMigrationWritesPreferencesAndStateOnlyToTargetDomain() throws {
        let targetDomainName = "LegacyMigrationRawTargetTests.\(UUID().uuidString)"
        let wrongCurrentDomainName = "LegacyMigrationRawCurrentTests.\(UUID().uuidString)"
        let targetDefaults = try XCTUnwrap(UserDefaults(suiteName: targetDomainName))
        let wrongCurrentDefaults = try XCTUnwrap(
            UserDefaults(suiteName: wrongCurrentDomainName)
        )
        let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LegacyMigrationRawTarget-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let destinationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LegacyMigrationRawTarget-destination-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            targetDefaults.removePersistentDomain(forName: targetDomainName)
            wrongCurrentDefaults.removePersistentDomain(forName: wrongCurrentDomainName)
            try? FileManager.default.removeItem(at: homeDirectory)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        wrongCurrentDefaults.set(
            "wrong-current-value",
            forKey: InkletPreferenceKeys.interfaceLanguage
        )
        XCTAssertTrue(wrongCurrentDefaults.synchronize())
        let defaultsFactories = LegacyMigrationDefaultsResolverRecorder(
            domainName: targetDomainName,
            writerDefaults: wrongCurrentDefaults
        )
        let resolver = LegacyMigrationExactDomainDefaultsResolver(
            currentBundleIdentifier: nil,
            currentDomainWriterFactory: { defaultsFactories.currentWriter() },
            freshCurrentDomainFactory: { defaultsFactories.freshCurrent() },
            suiteFactory: { defaultsFactories.suite(named: $0) }
        )
        let stateStore = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: targetDomainName,
            exactDomainResolver: resolver
        )
        let storagePaths = InkletStoragePaths(
            bundleIdentifier: targetDomainName,
            applicationSupportRootURL: destinationRoot,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        let legacyRoot = LegacySandboxDataMigrator.expectedLegacyDataRoot(
            bundleIdentifier: targetDomainName,
            homeDirectoryURL: homeDirectory
        )
        let preferencesURL = legacyRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(targetDomainName).plist")
        let fileSystem = MigrationTestFileSystem()
        fileSystem.setItemKind(.directory, at: legacyRoot)
        try fileSystem.setPropertyList(
            [InkletPreferenceKeys.interfaceLanguage: "legacy-language"],
            at: preferencesURL
        )
        let keychainClient = MigrationTestKeychainClient()
        let migrator = LegacySandboxDataMigrator(
            bundleIdentifier: targetDomainName,
            storagePaths: storagePaths,
            homeDirectoryURL: homeDirectory,
            exactDomainResolver: resolver,
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainStore: { providerID in
                KeychainStore(
                    service: "Inklet.RawMigrationTests",
                    account: providerID,
                    client: keychainClient
                )
            },
            lock: LegacyMigrationLock(
                fileURL: storagePaths.migrationLockFileURL,
                timeout: .milliseconds(100),
                retryInterval: .milliseconds(1)
            )
        )

        let outcome = migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.preferences], .completed(changedDestination: true))
        let targetDomain = try XCTUnwrap(
            targetDefaults.persistentDomain(forName: targetDomainName)
        )
        XCTAssertEqual(
            targetDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "legacy-language"
        )
        XCTAssertNotNil(
            targetDomain[UserDefaultsLegacyMigrationStateStore.preferenceBaselineKey] as? Data
        )
        XCTAssertEqual(
            targetDomain[
                UserDefaultsLegacyMigrationStateStore.completedVersionKey(for: .preferences)
            ] as? Int,
            LegacyMigrationVersions.preferences
        )
        XCTAssertEqual(
            wrongCurrentDefaults.persistentDomain(forName: wrongCurrentDomainName)?[
                InkletPreferenceKeys.interfaceLanguage
            ] as? String,
            "wrong-current-value"
        )
        XCTAssertEqual(defaultsFactories.currentWriterCount, 0)
        XCTAssertEqual(defaultsFactories.freshCurrentCount, 0)
        XCTAssertGreaterThan(defaultsFactories.suiteCount, 0)
    }

    func testStateStoreFailsClosedWhenTargetDefaultsDomainCannotBeOpened() throws {
        let currentDomainName = "LegacyMigrationUnavailableCurrent.\(UUID().uuidString)"
        let currentDefaults = try XCTUnwrap(UserDefaults(suiteName: currentDomainName))
        defer { currentDefaults.removePersistentDomain(forName: currentDomainName) }
        let currentDefaultsReference = FixedLegacyMigrationUserDefaultsFactory(
            defaults: currentDefaults
        )
        let resolver = LegacyMigrationExactDomainDefaultsResolver(
            currentBundleIdentifier: nil,
            currentDomainWriterFactory: { currentDefaultsReference.defaults },
            freshCurrentDomainFactory: { currentDefaultsReference.defaults },
            suiteFactory: { _ in nil }
        )
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: "LegacyMigrationUnavailableTarget.\(UUID().uuidString)",
            exactDomainResolver: resolver
        )

        XCTAssertThrowsError(try store.reload()) { error in
            XCTAssertEqual(
                error as? LegacyMigrationStateStoreError,
                .synchronizationFailed
            )
        }
        XCTAssertThrowsError(
            try store.setCompletedVersion(1, for: .preferences)
        ) { error in
            XCTAssertEqual(
                error as? LegacyMigrationStateStoreError,
                .synchronizationFailed
            )
        }
    }

    func testStateStoreIgnoresRegisteredMarkersAndBaselines() throws {
        let suiteName = "LegacyMigrationRegisteredDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let baseline: [String: PreferenceFingerprint] = [
            "setting": .present(sha256: String(repeating: "a", count: 64))
        ]
        defaults.register(defaults: [
            UserDefaultsLegacyMigrationStateStore.completedVersionKey(for: .preferences): 1,
            UserDefaultsLegacyMigrationStateStore.preferenceBaselineKey: try JSONEncoder().encode(
                baseline
            ),
        ])
        let defaultsFactory = FixedLegacyMigrationUserDefaultsFactory(defaults: defaults)
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: suiteName,
            exactDomainDefaultsFactory: { _ in defaultsFactory.defaults }
        )

        XCTAssertNil(try store.completedVersion(for: .preferences))
        XCTAssertNil(try store.preferenceBaseline())
        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?[
                UserDefaultsLegacyMigrationStateStore.completedVersionKey(for: .preferences)
            ]
        )
        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?[
                UserDefaultsLegacyMigrationStateStore.preferenceBaselineKey
            ]
        )
    }

    func testStateStoreReadsOnlyTheExactPersistentDomain() throws {
        let exactDomainName = "LegacyMigrationExactReadTests.\(UUID().uuidString)"
        let shadowDomainName = "\(exactDomainName).shadow"
        let exactDefaults = try XCTUnwrap(UserDefaults(suiteName: exactDomainName))
        let shadowDefaults = try XCTUnwrap(UserDefaults(suiteName: shadowDomainName))
        defer {
            exactDefaults.removeSuite(named: shadowDomainName)
            exactDefaults.removePersistentDomain(forName: exactDomainName)
            shadowDefaults.removePersistentDomain(forName: shadowDomainName)
        }
        let shadowBaseline: [String: PreferenceFingerprint] = ["shadow": .absent]
        shadowDefaults.set(
            9,
            forKey: UserDefaultsLegacyMigrationStateStore.completedVersionKey(for: .preferences)
        )
        shadowDefaults.set(
            try JSONEncoder().encode(shadowBaseline),
            forKey: UserDefaultsLegacyMigrationStateStore.preferenceBaselineKey
        )
        XCTAssertTrue(shadowDefaults.synchronize())
        exactDefaults.addSuite(named: shadowDomainName)
        XCTAssertEqual(
            exactDefaults.object(
                forKey: UserDefaultsLegacyMigrationStateStore.completedVersionKey(
                    for: .preferences
                )
            ) as? Int,
            9
        )
        let defaultsFactory = FixedLegacyMigrationUserDefaultsFactory(defaults: exactDefaults)
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: exactDomainName,
            exactDomainDefaultsFactory: { _ in defaultsFactory.defaults }
        )

        XCTAssertNil(try store.completedVersion(for: .preferences))
        XCTAssertNil(try store.preferenceBaseline())
    }

    func testStateStoreWritesOnlyTheExactPersistentDomain() throws {
        let exactDomainName = "LegacyMigrationExactWriteTests.\(UUID().uuidString)"
        let shadowDomainName = "\(exactDomainName).shadow"
        let exactDefaults = try XCTUnwrap(UserDefaults(suiteName: exactDomainName))
        let shadowDefaults = try XCTUnwrap(UserDefaults(suiteName: shadowDomainName))
        defer {
            exactDefaults.removePersistentDomain(forName: exactDomainName)
            shadowDefaults.removePersistentDomain(forName: shadowDomainName)
        }
        let exactBaseline: [String: PreferenceFingerprint] = ["exact": .absent]
        let shadowBaseline: [String: PreferenceFingerprint] = ["shadow": .absent]
        let credentialsKey = UserDefaultsLegacyMigrationStateStore.completedVersionKey(
            for: .credentials
        )
        shadowDefaults.set(9, forKey: credentialsKey)
        shadowDefaults.set(
            try JSONEncoder().encode(shadowBaseline),
            forKey: UserDefaultsLegacyMigrationStateStore.preferenceBaselineKey
        )
        XCTAssertTrue(shadowDefaults.synchronize())
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: exactDomainName
        )

        try store.setCompletedVersion(1, for: .credentials)
        try store.setPreferenceBaseline(exactBaseline)

        let exactDomain = try XCTUnwrap(
            UserDefaults(suiteName: exactDomainName)?.persistentDomain(forName: exactDomainName)
        )
        XCTAssertEqual(exactDomain[credentialsKey] as? Int, 1)
        let exactBaselineData = try XCTUnwrap(
            exactDomain[UserDefaultsLegacyMigrationStateStore.preferenceBaselineKey] as? Data
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [String: PreferenceFingerprint].self,
                from: exactBaselineData
            ),
            exactBaseline
        )
        let shadowDomain = try XCTUnwrap(
            shadowDefaults.persistentDomain(forName: shadowDomainName)
        )
        XCTAssertEqual(shadowDomain[credentialsKey] as? Int, 9)
        XCTAssertEqual(
            shadowDomain[UserDefaultsLegacyMigrationStateStore.preferenceBaselineKey] as? Data,
            try JSONEncoder().encode(shadowBaseline)
        )
    }

    func testStateStoreFailsClosedWhenInternalFactoryUsesMismatchedWriter() throws {
        let exactDomainName = "LegacyMigrationMismatchedWriterTests.\(UUID().uuidString)"
        let mismatchedDomainName = "\(exactDomainName).mismatched"
        let exactDefaults = try XCTUnwrap(UserDefaults(suiteName: exactDomainName))
        let mismatchedDefaults = try XCTUnwrap(UserDefaults(suiteName: mismatchedDomainName))
        defer {
            exactDefaults.removePersistentDomain(forName: exactDomainName)
            mismatchedDefaults.removePersistentDomain(forName: mismatchedDomainName)
        }
        let defaultsFactory = FixedLegacyMigrationUserDefaultsFactory(
            defaults: mismatchedDefaults
        )
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: exactDomainName,
            exactDomainDefaultsFactory: { _ in defaultsFactory.defaults }
        )

        XCTAssertThrowsError(
            try store.setCompletedVersion(1, for: .credentials)
        ) { error in
            XCTAssertEqual(
                error as? LegacyMigrationStateStoreError,
                .writeVerificationFailed
            )
        }
        XCTAssertNil(
            exactDefaults.persistentDomain(forName: exactDomainName)?[
                UserDefaultsLegacyMigrationStateStore.completedVersionKey(for: .credentials)
            ]
        )
    }

    func testStateStoreRestoresExactValueAfterWriteVerificationFails() throws {
        let suiteName = "LegacyMigrationRollbackVerificationTests.\(UUID().uuidString)"
        let key = UserDefaultsLegacyMigrationStateStore.completedVersionKey(for: .history)
        let writer = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { writer.removePersistentDomain(forName: suiteName) }
        writer.set(7, forKey: key)
        XCTAssertTrue(writer.synchronize())
        let sequence = SequencedLegacyMigrationUserDefaultsFactory(defaults: [
            writer,
            try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            try XCTUnwrap(EmptyPersistentDomainUserDefaults(suiteName: suiteName)),
            try XCTUnwrap(UserDefaults(suiteName: suiteName)),
        ])
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: suiteName,
            exactDomainDefaultsFactory: { _ in sequence.next() }
        )

        XCTAssertThrowsError(
            try store.setCompletedVersion(1, for: .history)
        ) { error in
            XCTAssertEqual(
                error as? LegacyMigrationStateStoreError,
                .writeVerificationFailed
            )
        }
        let freshDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertTrue(freshDefaults.synchronize())
        XCTAssertEqual(
            freshDefaults.persistentDomain(forName: suiteName)?[key] as? Int,
            7
        )
    }

    func testStateStorePerKeyWritePreservesExternalUnrelatedDefault() throws {
        let suiteName = "LegacyMigrationPerKeyWriteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: suiteName
        )
        _ = try runDefaultsCommand([
            "write",
            suiteName,
            "UnrelatedPreference",
            "-string",
            "preserved",
        ])

        try store.setCompletedVersion(1, for: .preferences)

        XCTAssertEqual(
            try runDefaultsCommand([
                "read",
                suiteName,
                "UnrelatedPreference",
            ]).trimmingCharacters(in: .whitespacesAndNewlines),
            "preserved"
        )
    }

    func testStateStoreReloadObservesMarkerWrittenByAnotherProcess() throws {
        let suiteName = "LegacyMigrationReloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: suiteName
        )

        XCTAssertNil(try store.completedVersion(for: .history))
        _ = try runDefaultsCommand([
            "write",
            suiteName,
            "Inklet.LegacySandboxMigration.historyVersion",
            "-int",
            "1",
        ])
        try store.reload()

        XCTAssertEqual(try store.completedVersion(for: .history), 1)
    }

    func testStateStoreRejectsBaselineEntriesThatAreNotLowercaseSHA256Digests() throws {
        let suiteName = "LegacyMigrationInvalidBaselineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: suiteName
        )

        let invalidDigests = [
            "known-plaintext-setting-value",
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ]
        for invalidDigest in invalidDigests {
            XCTAssertThrowsError(
                try store.setPreferenceBaseline([
                    "setting": .present(sha256: invalidDigest)
                ])
            ) { error in
                XCTAssertEqual(error as? LegacyMigrationStateStoreError, .invalidStoredValue)
            }
        }
        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?[
                UserDefaultsLegacyMigrationStateStore.preferenceBaselineKey
            ]
        )
    }

    func testStateStoreRejectsPresentBaselineValuesThatAreNotData() throws {
        let suiteName = "LegacyMigrationMalformedBaselineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: suiteName
        )
        let malformedValues: [Any] = [
            "not encoded data",
            ["setting": "plaintext"],
            1,
        ]

        for malformedValue in malformedValues {
            defaults.set(
                malformedValue,
                forKey: UserDefaultsLegacyMigrationStateStore.preferenceBaselineKey
            )

            XCTAssertThrowsError(try store.preferenceBaseline()) { error in
                XCTAssertEqual(error as? LegacyMigrationStateStoreError, .invalidStoredValue)
            }
        }
    }

    func testStateStoreDoesNotReportSuccessWhenSynchronizationFails() throws {
        let suiteName = "LegacyMigrationSynchronizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            FailingFirstSynchronizationUserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentialsKey = UserDefaultsLegacyMigrationStateStore.completedVersionKey(
            for: .credentials
        )
        defaults.register(defaults: [credentialsKey: 99])
        let defaultsFactory = SequencedLegacyMigrationUserDefaultsFactory(defaults: [
            defaults,
            try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            try XCTUnwrap(UserDefaults(suiteName: suiteName)),
        ])
        let store = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: suiteName,
            exactDomainDefaultsFactory: { _ in defaultsFactory.next() }
        )

        XCTAssertThrowsError(
            try store.setCompletedVersion(1, for: .credentials)
        ) { error in
            XCTAssertEqual(
                error as? LegacyMigrationStateStoreError,
                .synchronizationFailed
            )
        }
        XCTAssertNil(try store.completedVersion(for: .credentials))
        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?[credentialsKey]
        )

        let freshStore = UserDefaultsLegacyMigrationStateStore(
            persistentDomainName: suiteName
        )
        try freshStore.reload()
        XCTAssertNil(try freshStore.completedVersion(for: .credentials))
    }

    func testPreferencesMigrateOnlyRecognizedKeysAndCredentialsGoOnlyToKeychain() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let keychainClient = MigrationTestKeychainClient()
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainClient: keychainClient
        )
        let panelSize: [String: NSNumber] = [
            "width": NSNumber(value: 420.5),
            "height": NSNumber(value: 260),
        ]
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [
                InkletPreferenceKeys.appConfig: Data("config".utf8),
                InkletPreferenceKeys.modelCatalogSnapshot: Data("models".utf8),
                InkletPreferenceKeys.interfaceLanguage: "zh-CN",
                InkletPreferenceKeys.didCompleteOnboarding: true,
                InkletPreferenceKeys.translationPanelSize: panelSize,
                "AppleLanguages": ["private-shadow"],
                "arbitrary.system.preference": "must-not-migrate",
                "providerAPIKey.openai.preview.v1": "controlled-test-secret",
            ]
        )

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.preferences], .completed(changedDestination: true))
        XCTAssertEqual(outcome.results[.credentials], .completed(changedDestination: true))
        let domain = fixture.persistentDomain
        XCTAssertEqual(domain[InkletPreferenceKeys.appConfig] as? Data, Data("config".utf8))
        XCTAssertEqual(
            domain[InkletPreferenceKeys.modelCatalogSnapshot] as? Data,
            Data("models".utf8)
        )
        XCTAssertEqual(domain[InkletPreferenceKeys.interfaceLanguage] as? String, "zh-CN")
        XCTAssertEqual(domain[InkletPreferenceKeys.didCompleteOnboarding] as? Bool, true)
        XCTAssertEqual(
            domain[InkletPreferenceKeys.translationPanelSize] as? [String: NSNumber],
            panelSize
        )
        XCTAssertNil(domain["AppleLanguages"])
        XCTAssertNil(domain["arbitrary.system.preference"])
        XCTAssertNil(domain["providerAPIKey.openai.preview.v1"])
        XCTAssertEqual(fixture.keychainFactory.providerIDs, ["openai.preview.v1"])
        XCTAssertEqual(keychainClient.value(for: "openai.preview.v1"), "controlled-test-secret")
    }

    func testPreferencesRejectEveryMalformedRecognizedTypeBeforeAnyStaticWrite() throws {
        let malformedValues: [(String, Any)] = [
            (InkletPreferenceKeys.appConfig, "not-data"),
            (InkletPreferenceKeys.modelCatalogSnapshot, "not-data"),
            (InkletPreferenceKeys.interfaceLanguage, Data("not-string".utf8)),
            (InkletPreferenceKeys.didCompleteOnboarding, NSNumber(value: 1)),
            (InkletPreferenceKeys.translationPanelSize, ["width": true]),
            (InkletPreferenceKeys.translationPanelSize, ["width": "wide"]),
        ]

        for (malformedKey, malformedValue) in malformedValues {
            let fileSystem = MigrationTestFileSystem()
            let stateStore = MigrationTestStateStore()
            let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
            var preferences: [String: Any] = [
                InkletPreferenceKeys.interfaceLanguage: "zh-CN"
            ]
            preferences[malformedKey] = malformedValue
            if malformedKey == InkletPreferenceKeys.interfaceLanguage {
                preferences[InkletPreferenceKeys.appConfig] = Data("valid-config".utf8)
            }
            try configureLegacySources(
                fixture,
                fileSystem: fileSystem,
                preferences: preferences
            )

            let outcome = fixture.migrator.migrateAutomatically()

            assertIncomplete(outcome.results[.preferences], kind: .decodeFailed)
            XCTAssertNil(stateStore.versions[.preferences])
            for key in InkletPreferenceKeys.recognizedLegacyKeys {
                XCTAssertNil(fixture.persistentDomain[key])
            }
        }
    }

    func testFirstReadablePreferenceAttemptUsesLegacyPresentValuesAndPreservesAbsentValues() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fixture.defaults.set(Data("stale".utf8), forKey: InkletPreferenceKeys.appConfig)
        fixture.defaults.set("fr", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [
                InkletPreferenceKeys.appConfig: Data("legacy-authoritative".utf8),
            ]
        )

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.preferences], .completed(changedDestination: true))
        XCTAssertEqual(
            fixture.persistentDomain[InkletPreferenceKeys.appConfig] as? Data,
            Data("legacy-authoritative".utf8)
        )
        XCTAssertEqual(
            fixture.persistentDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "fr"
        )
    }

    func testExactPersistentDomainIgnoresRegisteredAndAddedSuiteShadows() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let shadowSuiteName = "\(fixture.bundleIdentifier).shadow"
        let primarySuiteName = fixture.bundleIdentifier
        let shadowDefaults = try XCTUnwrap(UserDefaults(suiteName: shadowSuiteName))
        addTeardownBlock {
            UserDefaults(suiteName: primarySuiteName)?.removeSuite(named: shadowSuiteName)
            UserDefaults(suiteName: shadowSuiteName)?.removePersistentDomain(
                forName: shadowSuiteName
            )
        }
        shadowDefaults.set("suite-shadow", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(shadowDefaults.synchronize())
        fixture.defaults.register(defaults: [
            InkletPreferenceKeys.appConfig: Data("registered-shadow".utf8)
        ])
        fixture.defaults.addSuite(named: shadowSuiteName)
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [
                InkletPreferenceKeys.appConfig: Data("legacy-config".utf8),
                InkletPreferenceKeys.interfaceLanguage: "legacy-language",
            ]
        )

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.preferences], .completed(changedDestination: true))
        let exactDomain = fixture.persistentDomain
        XCTAssertEqual(
            exactDomain[InkletPreferenceKeys.appConfig] as? Data,
            Data("legacy-config".utf8)
        )
        XCTAssertEqual(
            exactDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "legacy-language"
        )
    }

    func testCompletedComponentsStayCompleteWhileFailedComponentRetriesIndependently() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let keychainClient = MigrationTestKeychainClient()
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainClient: keychainClient
        )
        let legacyHistory = historyItem(idSuffix: 101, timestamp: 10, input: "legacy")
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [
                InkletPreferenceKeys.interfaceLanguage: "legacy-language",
                "providerAPIKey.openai": Data("malformed".utf8),
            ],
            history: try encodedHistory([legacyHistory])
        )

        let firstOutcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(firstOutcome.results[.preferences], .completed(changedDestination: true))
        assertIncomplete(firstOutcome.results[.credentials], kind: .decodeFailed)
        XCTAssertEqual(firstOutcome.results[.history], .completed(changedDestination: true))
        fixture.defaults.set("user-edit-after-completion", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        try fileSystem.setPropertyList(
            ["providerAPIKey.openai": "controlled-test-secret"],
            at: fixture.preferencesURL
        )
        let preferenceMarkerWrites = stateStore.setVersionCalls.filter { $0 == .preferences }.count
        let historyMarkerWrites = stateStore.setVersionCalls.filter { $0 == .history }.count
        let historyWrites = fileSystem.successfulWriteURLs.filter { $0 == fixture.historyDestinationURL }.count

        let retryOutcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(retryOutcome.results[.preferences], .alreadyComplete(version: 1))
        XCTAssertEqual(retryOutcome.results[.credentials], .completed(changedDestination: true))
        XCTAssertEqual(retryOutcome.results[.history], .alreadyComplete(version: 1))
        XCTAssertEqual(
            fixture.persistentDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "user-edit-after-completion"
        )
        XCTAssertEqual(
            stateStore.setVersionCalls.filter { $0 == .preferences }.count,
            preferenceMarkerWrites
        )
        XCTAssertEqual(
            stateStore.setVersionCalls.filter { $0 == .history }.count,
            historyMarkerWrites
        )
        XCTAssertEqual(
            fileSystem.successfulWriteURLs.filter { $0 == fixture.historyDestinationURL }.count,
            historyWrites
        )
    }

    func testDelayedPreferenceConflictsPreserveUserChangesAndResolveMarker() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let baselinePanel: [String: NSNumber] = ["width": 320, "height": 240]
        fixture.defaults.set(Data("baseline-config".utf8), forKey: InkletPreferenceKeys.appConfig)
        fixture.defaults.set("en", forKey: InkletPreferenceKeys.interfaceLanguage)
        fixture.defaults.set(true, forKey: InkletPreferenceKeys.didCompleteOnboarding)
        fixture.defaults.set(baselinePanel, forKey: InkletPreferenceKeys.translationPanelSize)
        XCTAssertTrue(fixture.defaults.synchronize())
        fileSystem.failItemKind(
            at: fixture.legacyRoot,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        )

        let deniedOutcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(deniedOutcome.results[.preferences], kind: .permissionDenied)
        XCTAssertEqual(
            Set(stateStore.baseline?.keys.map { $0 } ?? []),
            Set(InkletPreferenceKeys.recognizedLegacyKeys)
        )
        fixture.defaults.set(Data("added-by-user".utf8), forKey: InkletPreferenceKeys.modelCatalogSnapshot)
        fixture.defaults.set("fr", forKey: InkletPreferenceKeys.interfaceLanguage)
        fixture.defaults.removeObject(forKey: InkletPreferenceKeys.didCompleteOnboarding)
        let editedPanel: [String: NSNumber] = ["width": 777, "height": 555]
        fixture.defaults.set(editedPanel, forKey: InkletPreferenceKeys.translationPanelSize)
        XCTAssertTrue(fixture.defaults.synchronize())
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [
                InkletPreferenceKeys.appConfig: Data("legacy-config".utf8),
                InkletPreferenceKeys.modelCatalogSnapshot: Data("legacy-models".utf8),
                InkletPreferenceKeys.interfaceLanguage: "zh-CN",
                InkletPreferenceKeys.didCompleteOnboarding: false,
            ]
        )

        let retryOutcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(retryOutcome.results[.preferences], .completed(changedDestination: true))
        let domain = fixture.persistentDomain
        XCTAssertEqual(
            domain[InkletPreferenceKeys.appConfig] as? Data,
            Data("legacy-config".utf8)
        )
        XCTAssertEqual(
            domain[InkletPreferenceKeys.modelCatalogSnapshot] as? Data,
            Data("added-by-user".utf8)
        )
        XCTAssertEqual(domain[InkletPreferenceKeys.interfaceLanguage] as? String, "fr")
        XCTAssertNil(domain[InkletPreferenceKeys.didCompleteOnboarding])
        XCTAssertEqual(
            domain[InkletPreferenceKeys.translationPanelSize] as? [String: NSNumber],
            editedPanel
        )
        XCTAssertEqual(stateStore.versions[.preferences], 1)
    }

    func testAutomaticAccessFailurePersistsVerifiedDigestOnlyBaselineForAllKeys() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let plaintext = "must-not-appear-in-baseline"
        fixture.defaults.set(plaintext, forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        fileSystem.failItemKind(
            at: fixture.preferencesURL,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        )
        fileSystem.setItemKind(.directory, at: fixture.legacyRoot)

        let outcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(outcome.results[.preferences], kind: .indeterminateLookup)
        let baseline = try XCTUnwrap(stateStore.baseline)
        XCTAssertEqual(Set(baseline.keys), Set(InkletPreferenceKeys.recognizedLegacyKeys))
        XCTAssertEqual(baseline[InkletPreferenceKeys.appConfig], .absent)
        guard case let .present(digest)? = baseline[InkletPreferenceKeys.interfaceLanguage] else {
            return XCTFail("Expected a digest-only baseline")
        }
        XCTAssertEqual(digest.count, 64)
        XCTAssertFalse(digest.contains(plaintext))
        XCTAssertEqual(fileSystem.data(at: fixture.preferenceAttemptGuardURL), fixture.guardContents)
    }

    func testBaselinePersistenceFailureLeavesDurableGuardAndFutureInstanceFailsClosed() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        stateStore.failSetBaseline = true
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fixture.defaults.set("stale", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [InkletPreferenceKeys.interfaceLanguage: "legacy"]
        )

        let firstOutcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(firstOutcome.results[.preferences], kind: .writeFailed)
        XCTAssertNotNil(fileSystem.data(at: fixture.preferenceAttemptGuardURL))
        XCTAssertNil(stateStore.baseline)
        fixture.defaults.set("user-edit", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        stateStore.failSetBaseline = false
        let secondMigrator = fixture.makeFreshMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore
        )

        let retryOutcome = secondMigrator.migrateAutomatically()

        assertIncomplete(retryOutcome.results[.preferences], kind: .writeFailed)
        XCTAssertEqual(
            fixture.persistentDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "user-edit"
        )
        XCTAssertNil(stateStore.versions[.preferences])
    }

    func testBaselineReadbackFailureRemainsFailClosedAcrossFreshInstance() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        stateStore.failBaselineReadAfterSet = true
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fixture.defaults.set("initial", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [InkletPreferenceKeys.interfaceLanguage: "legacy"]
        )

        let firstOutcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(firstOutcome.results[.preferences], kind: .writeFailed)
        XCTAssertNotNil(stateStore.baseline)
        fixture.defaults.set("post-failure-edit", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        stateStore.failBaselineReadAfterSet = false
        let freshMigrator = fixture.makeFreshMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore
        )

        let retryOutcome = freshMigrator.migrateAutomatically()

        assertIncomplete(retryOutcome.results[.preferences], kind: .writeFailed)
        XCTAssertNil(stateStore.versions[.preferences])
        XCTAssertEqual(
            fixture.persistentDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "post-failure-edit"
        )
    }

    func testPreferenceAttemptGuardPostRenameDurabilityFailureStaysFailClosed() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fileSystem.failWriteAfterReplacing(
            at: fixture.preferenceAttemptGuardURL,
            onAttempt: 1,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        )
        fixture.defaults.set("initial", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [InkletPreferenceKeys.interfaceLanguage: "legacy"]
        )

        let firstOutcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(firstOutcome.results[.preferences], kind: .writeFailed)
        XCTAssertFalse(firstOutcome.changedDestination)
        XCTAssertNil(stateStore.baseline)
        XCTAssertEqual(
            fileSystem.data(at: fixture.preferenceAttemptGuardURL),
            fixture.attemptedGuardContents
        )
        fixture.defaults.set("post-failure-edit", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())

        let retryOutcome = fixture.makeFreshMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore
        ).migrateAutomatically()

        assertIncomplete(retryOutcome.results[.preferences], kind: .writeFailed)
        XCTAssertEqual(
            fixture.persistentDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "post-failure-edit"
        )
        XCTAssertNil(stateStore.versions[.preferences])
    }

    func testPreferenceVerifiedGuardPostRenameDurabilityFailureStaysFailClosed() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fileSystem.failWriteAfterReplacing(
            at: fixture.preferenceAttemptGuardURL,
            onAttempt: 2,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        )
        fixture.defaults.set("initial", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [InkletPreferenceKeys.interfaceLanguage: "legacy"]
        )

        let firstOutcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(firstOutcome.results[.preferences], kind: .writeFailed)
        XCTAssertFalse(firstOutcome.changedDestination)
        XCTAssertNil(stateStore.baseline)
        XCTAssertEqual(
            fileSystem.data(at: fixture.preferenceAttemptGuardURL),
            fixture.guardContents
        )
        fixture.defaults.set("post-failure-edit", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())

        let retryOutcome = fixture.makeFreshMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore
        ).migrateAutomatically()

        assertIncomplete(retryOutcome.results[.preferences], kind: .writeFailed)
        XCTAssertEqual(
            fixture.persistentDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "post-failure-edit"
        )
        XCTAssertNil(stateStore.versions[.preferences])
    }

    func testAttemptGuardWriteFailurePreventsPreferenceOverwrite() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fileSystem.failWrite(
            at: fixture.preferenceAttemptGuardURL,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        )
        fixture.defaults.set("stale", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [InkletPreferenceKeys.interfaceLanguage: "legacy"]
        )

        let outcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(outcome.results[.preferences], kind: .writeFailed)
        XCTAssertEqual(
            fixture.persistentDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "stale"
        )
        XCTAssertNil(stateStore.baseline)
    }

    func testUserAssistedAttemptWithoutVerifiedBaselineFailsClosed() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fixture.defaults.set("user-current", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [InkletPreferenceKeys.interfaceLanguage: "legacy"]
        )

        let outcome = fixture.migrator.migrateUserSelectedData(at: fixture.legacyRoot)

        assertIncomplete(outcome.results[.preferences], kind: .writeFailed)
        XCTAssertEqual(
            fixture.persistentDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "user-current"
        )
        XCTAssertNil(stateStore.baseline)
    }

    func testPreferenceMarkerFailureReportsMutationAndRetryProtectsLaterEdit() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        stateStore.markerFailures.insert(.preferences)
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [InkletPreferenceKeys.interfaceLanguage: "legacy"]
        )

        let firstOutcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(firstOutcome.results[.preferences], kind: .writeFailed)
        XCTAssertTrue(firstOutcome.changedDestination)
        fixture.defaults.set("later-user-edit", forKey: InkletPreferenceKeys.interfaceLanguage)
        XCTAssertTrue(fixture.defaults.synchronize())
        stateStore.markerFailures.remove(.preferences)

        let retryOutcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(retryOutcome.results[.preferences], .completed(changedDestination: false))
        XCTAssertEqual(
            fixture.persistentDomain[InkletPreferenceKeys.interfaceLanguage] as? String,
            "later-user-edit"
        )
    }

    func testCredentialKeysRequireNonemptyProviderIDAndStringValuesBeforeKeychainMutation() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let keychainClient = MigrationTestKeychainClient()
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainClient: keychainClient
        )
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [
                "providerAPIKey.": Data("ignored-empty-provider".utf8),
                "not-providerAPIKey.openai": "ignored",
                "providerAPIKey.a": "controlled-a",
                "providerAPIKey.b": Data("malformed".utf8),
            ]
        )

        let outcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(outcome.results[.credentials], kind: .decodeFailed)
        XCTAssertTrue(fixture.keychainFactory.providerIDs.isEmpty)
        XCTAssertTrue(keychainClient.allValues.isEmpty)
        XCTAssertNil(fixture.persistentDomain["providerAPIKey.a"])
        XCTAssertNil(fixture.persistentDomain["providerAPIKey.b"])
    }

    func testMalformedStaticPreferenceDoesNotBlockValidCredentialMigration() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let keychainClient = MigrationTestKeychainClient()
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainClient: keychainClient
        )
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [
                InkletPreferenceKeys.appConfig: "malformed-static-value",
                "providerAPIKey.openai": "controlled-key",
            ]
        )

        let outcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(outcome.results[.preferences], kind: .decodeFailed)
        XCTAssertEqual(outcome.results[.credentials], .completed(changedDestination: true))
        XCTAssertEqual(keychainClient.value(for: "openai"), "controlled-key")
        XCTAssertNil(fixture.persistentDomain[InkletPreferenceKeys.appConfig])
    }

    func testMalformedPlistDecodeFailsBothStillIncompletePlistComponents() {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fileSystem.setItemKind(.directory, at: fixture.legacyRoot)
        fileSystem.setData(Data("not-a-property-list".utf8), at: fixture.preferencesURL)

        let outcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(outcome.results[.preferences], kind: .decodeFailed)
        assertIncomplete(outcome.results[.credentials], kind: .decodeFailed)
        XCTAssertNotNil(stateStore.baseline)
        XCTAssertNil(stateStore.versions[.preferences])
        XCTAssertNil(stateStore.versions[.credentials])
    }

    func testCredentialsPassDottedProviderIDAndKeepExistingKeychainItem() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let keychainClient = MigrationTestKeychainClient(values: [
            "existing": "existing-keychain-value"
        ])
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainClient: keychainClient
        )
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [
                "providerAPIKey.existing": "legacy-must-not-overwrite",
                "providerAPIKey.vendor.region.preview": "controlled-new-value",
            ]
        )

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.credentials], .completed(changedDestination: true))
        XCTAssertEqual(
            fixture.keychainFactory.providerIDs,
            ["existing", "vendor.region.preview"]
        )
        XCTAssertEqual(keychainClient.value(for: "existing"), "existing-keychain-value")
        XCTAssertEqual(
            keychainClient.value(for: "vendor.region.preview"),
            "controlled-new-value"
        )
        XCTAssertEqual(keychainClient.saveCount(for: "existing"), 0)
        XCTAssertEqual(keychainClient.saveCount(for: "vendor.region.preview"), 1)
        XCTAssertNil(fixture.persistentDomain["providerAPIKey.existing"])
        XCTAssertNil(fixture.persistentDomain["providerAPIKey.vendor.region.preview"])
    }

    func testCredentialCreateRacePreservesExistingItemWithoutUpdateOrMutation() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let keychainClient = MigrationTestKeychainClient()
        keychainClient.insertBeforeNextAdd(
            "concurrent-keychain-value",
            for: "provider.race"
        )
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainClient: keychainClient
        )
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [
                "providerAPIKey.provider.race": "legacy-must-not-overwrite"
            ]
        )

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.credentials], .completed(changedDestination: false))
        XCTAssertFalse(outcome.changedDestination)
        XCTAssertEqual(
            keychainClient.value(for: "provider.race"),
            "concurrent-keychain-value"
        )
        XCTAssertEqual(keychainClient.updateCount(for: "provider.race"), 0)
        XCTAssertEqual(keychainClient.addCount(for: "provider.race"), 1)
        XCTAssertEqual(stateStore.versions[.credentials], 1)
        XCTAssertNil(fixture.persistentDomain["providerAPIKey.provider.race"])
    }

    func testCredentialLoadFailureIsPrivacySafeAndRetryable() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let keychainClient = MigrationTestKeychainClient()
        keychainClient.loadFailureAccounts.insert("provider.private")
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainClient: keychainClient
        )
        let secret = "never-in-failure-text"
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: ["providerAPIKey.provider.private": secret]
        )

        let outcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(outcome.results[.credentials], kind: .keychainFailed)
        XCTAssertNil(stateStore.versions[.credentials])
        XCTAssertNil(fixture.persistentDomain["providerAPIKey.provider.private"])
        guard case let .incomplete(failure)? = outcome.results[.credentials] else {
            return XCTFail("Expected a credential failure")
        }
        let failureText = [
            failure.sourceLabel,
            failure.destinationLabel ?? "",
            failure.nonSensitiveDescription,
        ].joined(separator: " ")
        XCTAssertFalse(failureText.contains(secret))
        XCTAssertFalse(failureText.contains("provider.private"))
        XCTAssertFalse(failureText.contains(fixture.legacyRoot.path))
    }

    func testPartialCredentialSavesAreIdempotentOnRetry() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let keychainClient = MigrationTestKeychainClient()
        keychainClient.saveFailureAccounts.insert("b")
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainClient: keychainClient
        )
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [
                "providerAPIKey.a": "controlled-a",
                "providerAPIKey.b": "controlled-b",
            ]
        )

        let firstOutcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(firstOutcome.results[.credentials], kind: .keychainFailed)
        XCTAssertTrue(firstOutcome.changedDestination)
        XCTAssertEqual(keychainClient.value(for: "a"), "controlled-a")
        XCTAssertNil(keychainClient.value(for: "b"))
        XCTAssertEqual(keychainClient.saveCount(for: "a"), 1)
        keychainClient.saveFailureAccounts.remove("b")

        let retryOutcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(retryOutcome.results[.credentials], .completed(changedDestination: true))
        XCTAssertEqual(keychainClient.value(for: "a"), "controlled-a")
        XCTAssertEqual(keychainClient.value(for: "b"), "controlled-b")
        XCTAssertEqual(keychainClient.saveCount(for: "a"), 1)
        XCTAssertEqual(keychainClient.saveCount(for: "b"), 1)
        XCTAssertEqual(stateStore.versions[.credentials], 1)
    }

    func testCredentialMarkerFailureRemainsIncompleteWithoutSavingAgain() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        stateStore.markerFailures.insert(.credentials)
        let keychainClient = MigrationTestKeychainClient()
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainClient: keychainClient
        )
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: ["providerAPIKey.openai": "controlled-value"]
        )

        let firstOutcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(firstOutcome.results[.credentials], kind: .writeFailed)
        XCTAssertTrue(firstOutcome.changedDestination)
        XCTAssertEqual(keychainClient.saveCount(for: "openai"), 1)
        stateStore.markerFailures.remove(.credentials)

        let retryOutcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(retryOutcome.results[.credentials], .completed(changedDestination: false))
        XCTAssertEqual(keychainClient.saveCount(for: "openai"), 1)
    }

    func testHistoryMergeUsesDestinationOnCollisionDeduplicatesAndSortsDeterministically() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let legacyCollision = HistoryItem(
            id: sharedID,
            createdAt: Date(timeIntervalSince1970: 40),
            source: .write,
            inputText: "legacy-collision",
            outputText: "legacy"
        )
        let destinationCollision = HistoryItem(
            id: sharedID,
            createdAt: Date(timeIntervalSince1970: 30),
            source: .selection,
            inputText: "destination-wins",
            outputText: "destination"
        )
        let tieLaterUUID = historyItem(idSuffix: 203, timestamp: 20, input: "tie-later")
        let tieEarlierUUID = historyItem(idSuffix: 202, timestamp: 20, input: "tie-earlier")
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [:],
            history: try encodedHistory([
                tieLaterUUID,
                legacyCollision,
                tieEarlierUUID,
                tieEarlierUUID,
            ])
        )
        fileSystem.setData(
            try encodedHistory([destinationCollision, destinationCollision]),
            at: fixture.historyDestinationURL
        )
        let sourceBytes = try XCTUnwrap(fileSystem.data(at: fixture.historyURL))

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.history], .completed(changedDestination: true))
        let destinationBytes = try XCTUnwrap(fileSystem.data(at: fixture.historyDestinationURL))
        XCTAssertEqual(
            HistoryJSONLCodec.decodeValidItems(from: destinationBytes),
            [tieEarlierUUID, tieLaterUUID, destinationCollision]
        )
        XCTAssertEqual(fileSystem.data(at: fixture.historyURL), sourceBytes)
    }

    func testHistorySkipsMalformedLinesAndRetryCannotDuplicateUUIDs() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        stateStore.markerFailures.insert(.history)
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let item = historyItem(idSuffix: 211, timestamp: 10, input: "valid")
        let legacyBytes = Data("malformed\n".utf8) + (try encodedHistory([item, item]))
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [:],
            history: legacyBytes
        )

        let firstOutcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(firstOutcome.results[.history], kind: .writeFailed)
        XCTAssertTrue(firstOutcome.changedDestination)
        XCTAssertEqual(
            HistoryJSONLCodec.decodeValidItems(
                from: try XCTUnwrap(fileSystem.data(at: fixture.historyDestinationURL))
            ),
            [item]
        )
        XCTAssertEqual(fileSystem.data(at: fixture.historyURL), legacyBytes)
        stateStore.markerFailures.remove(.history)
        let writeCount = fileSystem.successfulWriteURLs.filter {
            $0 == fixture.historyDestinationURL
        }.count

        let retryOutcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(retryOutcome.results[.history], .completed(changedDestination: false))
        XCTAssertEqual(
            fileSystem.successfulWriteURLs.filter { $0 == fixture.historyDestinationURL }.count,
            writeCount
        )
        XCTAssertEqual(fileSystem.data(at: fixture.historyURL), legacyBytes)
    }

    func testHistoryDropsMalformedDestinationLinesWhilePreservingValidRecords() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let legacyItem = historyItem(idSuffix: 215, timestamp: 10, input: "legacy")
        let destinationItem = historyItem(idSuffix: 216, timestamp: 20, input: "destination")
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [:],
            history: try encodedHistory([legacyItem])
        )
        fileSystem.setData(
            Data("malformed-destination\n".utf8) + (try encodedHistory([destinationItem])),
            at: fixture.historyDestinationURL
        )

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.history], .completed(changedDestination: true))
        XCTAssertEqual(
            fileSystem.data(at: fixture.historyDestinationURL),
            try encodedHistory([legacyItem, destinationItem])
        )
    }

    func testHistoryDestinationReadFailureStaysIncompleteWithoutRewrite() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let destinationBytes = try encodedHistory([
            historyItem(idSuffix: 217, timestamp: 20, input: "destination")
        ])
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [:],
            history: try encodedHistory([
                historyItem(idSuffix: 218, timestamp: 10, input: "legacy")
            ])
        )
        fileSystem.setData(destinationBytes, at: fixture.historyDestinationURL)
        fileSystem.failRead(
            at: fixture.historyDestinationURL,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        )

        let outcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(outcome.results[.history], kind: .readFailed)
        XCTAssertEqual(fileSystem.data(at: fixture.historyDestinationURL), destinationBytes)
        XCTAssertFalse(fileSystem.successfulWriteURLs.contains(fixture.historyDestinationURL))
        XCTAssertNil(stateStore.versions[.history])
    }

    func testHistoryAtomicWriteFailurePreservesDestinationAndMarker() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let legacyItem = historyItem(idSuffix: 221, timestamp: 10, input: "legacy")
        let destinationItem = historyItem(idSuffix: 222, timestamp: 20, input: "destination")
        let legacyBytes = try encodedHistory([legacyItem])
        let destinationBytes = try encodedHistory([destinationItem])
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [:],
            history: legacyBytes
        )
        fileSystem.setData(destinationBytes, at: fixture.historyDestinationURL)
        fileSystem.failWrite(
            at: fixture.historyDestinationURL,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        )

        let outcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(outcome.results[.history], kind: .writeFailed)
        XCTAssertFalse(outcome.changedDestination)
        XCTAssertEqual(fileSystem.data(at: fixture.historyDestinationURL), destinationBytes)
        XCTAssertEqual(fileSystem.data(at: fixture.historyURL), legacyBytes)
        XCTAssertNil(stateStore.versions[.history])
    }

    func testHistoryPostRenameDurabilityFailureReportsMutationAndRetriesIdempotently() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let legacyItem = historyItem(idSuffix: 223, timestamp: 10, input: "legacy")
        let destinationItem = historyItem(idSuffix: 224, timestamp: 20, input: "destination")
        let legacyBytes = try encodedHistory([legacyItem])
        let mergedBytes = try encodedHistory([legacyItem, destinationItem])
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [:],
            history: legacyBytes
        )
        fileSystem.setData(
            try encodedHistory([destinationItem]),
            at: fixture.historyDestinationURL
        )
        fileSystem.failWriteAfterReplacing(
            at: fixture.historyDestinationURL,
            onAttempt: 1,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        )

        let firstOutcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(firstOutcome.results[.history], kind: .writeFailed)
        XCTAssertTrue(firstOutcome.changedDestination)
        XCTAssertEqual(fileSystem.data(at: fixture.historyDestinationURL), mergedBytes)
        XCTAssertEqual(fileSystem.data(at: fixture.historyURL), legacyBytes)
        XCTAssertNil(stateStore.versions[.history])

        let retryOutcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(retryOutcome.results[.history], .completed(changedDestination: false))
        XCTAssertEqual(fileSystem.data(at: fixture.historyDestinationURL), mergedBytes)
        XCTAssertEqual(
            HistoryJSONLCodec.decodeValidItems(from: mergedBytes).map(\.id),
            [legacyItem.id, destinationItem.id]
        )
        XCTAssertEqual(
            fileSystem.writeDataURLs.filter { $0 == fixture.historyDestinationURL }.count,
            1
        )
        XCTAssertEqual(stateStore.versions[.history], 1)
    }

    func testHistoryDirectoryCloseFailureReportsMutationAndRetriesIdempotently() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LegacyMigrationHistoryCloseFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let bundleIdentifier = "com.example.inklet.close-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: bundleIdentifier))
        defer { defaults.removePersistentDomain(forName: bundleIdentifier) }
        let homeDirectory = rootURL.appendingPathComponent("home", isDirectory: true)
        let destinationRoot = rootURL.appendingPathComponent("destination", isDirectory: true)
        let storagePaths = InkletStoragePaths(
            bundleIdentifier: bundleIdentifier,
            applicationSupportRootURL: destinationRoot,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        let legacyRoot = LegacySandboxDataMigrator.expectedLegacyDataRoot(
            bundleIdentifier: bundleIdentifier,
            homeDirectoryURL: homeDirectory
        )
        let legacyHistoryURL = legacyRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Inklet", isDirectory: true)
            .appendingPathComponent("history.jsonl")
        let legacyItem = historyItem(idSuffix: 225, timestamp: 10, input: "legacy")
        let legacyBytes = try encodedHistory([legacyItem])
        try FileManager.default.createDirectory(
            at: legacyHistoryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyBytes.write(to: legacyHistoryURL)
        let closeFailure = FailingOnceDirectoryCloseOperation(errorCode: EIO)
        let fileSystem = FileManagerLegacyMigrationFileSystem(
            directorySyncOperations: LegacyMigrationDirectorySyncOperations(
                openDirectory: { path in
                    Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                },
                synchronize: { Darwin.fsync($0) },
                close: { closeFailure.close($0) }
            )
        )
        let stateStore = MigrationTestStateStore()
        stateStore.versions[.preferences] = LegacyMigrationVersions.preferences
        stateStore.versions[.credentials] = LegacyMigrationVersions.credentials
        let keychainClient = MigrationTestKeychainClient()
        let migrator = LegacySandboxDataMigrator(
            bundleIdentifier: bundleIdentifier,
            storagePaths: storagePaths,
            homeDirectoryURL: homeDirectory,
            defaults: defaults,
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainStore: { providerID in
                KeychainStore(
                    service: "Inklet.MigrationCloseTests",
                    account: providerID,
                    client: keychainClient
                )
            },
            lock: LegacyMigrationLock(
                fileURL: storagePaths.migrationLockFileURL,
                timeout: .milliseconds(100),
                retryInterval: .milliseconds(1)
            )
        )

        let firstOutcome = migrator.migrateAutomatically()

        assertIncomplete(firstOutcome.results[.history], kind: .writeFailed)
        XCTAssertTrue(firstOutcome.changedDestination)
        XCTAssertEqual(try Data(contentsOf: storagePaths.historyFileURL), legacyBytes)
        XCTAssertEqual(try Data(contentsOf: legacyHistoryURL), legacyBytes)
        XCTAssertNil(stateStore.versions[.history])
        XCTAssertEqual(closeFailure.callCount, 1)

        let retryOutcome = migrator.migrateAutomatically()

        XCTAssertEqual(retryOutcome.results[.history], .completed(changedDestination: false))
        XCTAssertFalse(retryOutcome.changedDestination)
        XCTAssertEqual(
            HistoryJSONLCodec.decodeValidItems(
                from: try Data(contentsOf: storagePaths.historyFileURL)
            ),
            [legacyItem]
        )
        XCTAssertEqual(try Data(contentsOf: legacyHistoryURL), legacyBytes)
        XCTAssertEqual(stateStore.versions[.history], LegacyMigrationVersions.history)
        XCTAssertEqual(closeFailure.callCount, 1)
    }

    func testHistoryDoesNotRewriteAlreadyCanonicalMergedBytes() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let first = historyItem(idSuffix: 231, timestamp: 10, input: "first")
        let second = historyItem(idSuffix: 232, timestamp: 20, input: "second")
        let canonicalBytes = try encodedHistory([first, second])
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [:],
            history: try encodedHistory([first])
        )
        fileSystem.setData(canonicalBytes, at: fixture.historyDestinationURL)

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.history], .completed(changedDestination: false))
        XCTAssertFalse(fileSystem.successfulWriteURLs.contains(fixture.historyDestinationURL))
        XCTAssertEqual(fileSystem.data(at: fixture.historyDestinationURL), canonicalBytes)
    }

    func testHistoryDestinationMissingIsEmptyButReadAndTypeErrorsStayIncomplete() throws {
        do {
            let fileSystem = MigrationTestFileSystem()
            let stateStore = MigrationTestStateStore()
            let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
            let item = historyItem(idSuffix: 241, timestamp: 10, input: "legacy")
            try configureLegacySources(
                fixture,
                fileSystem: fileSystem,
                preferences: [:],
                history: try encodedHistory([item])
            )

            let outcome = fixture.migrator.migrateAutomatically()

            XCTAssertEqual(outcome.results[.history], .completed(changedDestination: true))
            XCTAssertEqual(
                HistoryJSONLCodec.decodeValidItems(
                    from: try XCTUnwrap(fileSystem.data(at: fixture.historyDestinationURL))
                ),
                [item]
            )
        }

        for destinationFailure in [
            Result<LegacyMigrationItemKind, NSError>.success(.directory),
            .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))),
        ] {
            let fileSystem = MigrationTestFileSystem()
            let stateStore = MigrationTestStateStore()
            let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
            try configureLegacySources(
                fixture,
                fileSystem: fileSystem,
                preferences: [:],
                history: try encodedHistory([
                    historyItem(idSuffix: 242, timestamp: 10, input: "legacy")
                ])
            )
            fileSystem.setItemKindResult(destinationFailure, at: fixture.historyDestinationURL)

            let outcome = fixture.migrator.migrateAutomatically()

            guard case .incomplete? = outcome.results[.history] else {
                return XCTFail("Expected destination failure to stay incomplete")
            }
            XCTAssertNil(stateStore.versions[.history])
        }
    }

    func testHistoryDestinationDisappearingAfterRegularLookupFailsWithoutImport() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let legacyBytes = try encodedHistory([
            historyItem(idSuffix: 245, timestamp: 10, input: "legacy")
        ])
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [:],
            history: legacyBytes
        )
        fileSystem.setItemKind(.regularFile, at: fixture.historyDestinationURL)
        fileSystem.failRead(
            at: fixture.historyDestinationURL,
            with: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        )

        let outcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(outcome.results[.history], kind: .readFailed)
        XCTAssertFalse(outcome.changedDestination)
        XCTAssertFalse(fileSystem.writeDataURLs.contains(fixture.historyDestinationURL))
        XCTAssertEqual(fileSystem.data(at: fixture.historyURL), legacyBytes)
        XCTAssertNil(stateStore.versions[.history])
    }

    func testComponentsCompleteAndFailIndependentlyWhileOutcomeRetainsAnyMutation() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [
                InkletPreferenceKeys.interfaceLanguage: "legacy-language",
                "providerAPIKey.openai": Data("malformed".utf8),
            ],
            history: try encodedHistory([
                historyItem(idSuffix: 251, timestamp: 10, input: "history")
            ])
        )

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.preferences], .completed(changedDestination: true))
        assertIncomplete(outcome.results[.credentials], kind: .decodeFailed)
        XCTAssertEqual(outcome.results[.history], .completed(changedDestination: true))
        XCTAssertTrue(outcome.hasIncompleteComponents)
        XCTAssertTrue(outcome.changedDestination)
    }

    func testFailureLabelsAndDescriptionsNeverExposeAbsolutePathsOrData() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let secretPathFragment = "private-user-secret-path"
        fileSystem.setItemKind(.directory, at: fixture.legacyRoot)
        fileSystem.setItemKind(.regularFile, at: fixture.preferencesURL)
        fileSystem.failRead(
            at: fixture.preferencesURL,
            with: NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EIO),
                userInfo: [NSLocalizedDescriptionKey: secretPathFragment]
            )
        )

        let outcome = fixture.migrator.migrateAutomatically()

        for component in [LegacyMigrationComponent.preferences, .credentials] {
            guard case let .incomplete(failure)? = outcome.results[component] else {
                return XCTFail("Expected source read failure")
            }
            XCTAssertEqual(failure.kind, .readFailed)
            let failureText = [
                failure.sourceLabel,
                failure.destinationLabel ?? "",
                failure.nonSensitiveDescription,
            ].joined(separator: " ")
            XCTAssertFalse(failureText.contains(fixture.legacyRoot.path))
            XCTAssertFalse(failureText.contains(secretPathFragment))
            XCTAssertFalse(failureText.contains("/Users/"))
        }
    }

    func testMigrationNeverAccessesLegacyOrDestinationTranslationCache() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [InkletPreferenceKeys.interfaceLanguage: "legacy"],
            history: try encodedHistory([
                historyItem(idSuffix: 261, timestamp: 10, input: "history")
            ])
        )

        _ = fixture.migrator.migrateAutomatically()

        XCTAssertFalse(fileSystem.allURLs.contains { url in
            url.path.contains("selection-translation-cache")
        })
    }

    func testLiveFileSystemReadRejectsFinalSymlink() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LegacyMigrationNoFollowTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let targetURL = rootURL.appendingPathComponent("target")
        let symlinkURL = rootURL.appendingPathComponent("link")
        try Data("source".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        let fileSystem = FileManagerLegacyMigrationFileSystem()

        XCTAssertThrowsError(try fileSystem.readData(at: symlinkURL)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(nsError.code, Int(ELOOP))
        }
        XCTAssertEqual(try fileSystem.readData(at: targetURL), Data("source".utf8))
    }

    func testLiveAtomicWriterPreservesOldDestinationWhenTempCreationFails() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LegacyMigrationAtomicFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let longName = String(repeating: "a", count: 250)
        let destinationURL = rootURL.appendingPathComponent(longName)
        let oldBytes = Data("old-destination".utf8)
        try oldBytes.write(to: destinationURL)
        let fileSystem = FileManagerLegacyMigrationFileSystem()

        XCTAssertThrowsError(
            try fileSystem.writeDataAtomically(Data("new-destination".utf8), to: destinationURL)
        )
        XCTAssertEqual(try Data(contentsOf: destinationURL), oldBytes)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path),
            [longName]
        )
    }

    func testLiveAtomicWriterReplacesDestinationWithRestrictivePermissionsAndNoTemp() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LegacyMigrationAtomicSuccessTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let destinationURL = rootURL.appendingPathComponent("history.jsonl")
        let fileSystem = FileManagerLegacyMigrationFileSystem()
        try fileSystem.writeDataAtomically(Data("old".utf8), to: destinationURL)

        try fileSystem.writeDataAtomically(Data("new".utf8), to: destinationURL)

        XCTAssertEqual(try fileSystem.readData(at: destinationURL), Data("new".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path),
            ["history.jsonl"]
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testLiveAtomicWriterPropagatesDirectoryOpenFailureAfterReplacingDestination() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LegacyMigrationDirectoryOpenFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let destinationURL = rootURL.appendingPathComponent("history.jsonl")
        try Data("old".utf8).write(to: destinationURL)
        let fileSystem = FileManagerLegacyMigrationFileSystem(
            directorySyncOperations: LegacyMigrationDirectorySyncOperations(
                openDirectory: { _ in
                    errno = EACCES
                    return -1
                },
                synchronize: { Darwin.fsync($0) },
                close: { Darwin.close($0) }
            )
        )

        XCTAssertThrowsError(
            try fileSystem.writeDataAtomically(Data("new".utf8), to: destinationURL)
        ) { error in
            let writeError = error as? LegacyMigrationAtomicWriteError
            XCTAssertEqual(writeError?.destinationWasReplaced, true)
            XCTAssertEqual(writeError?.posixCode, EACCES)
        }
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("new".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path),
            ["history.jsonl"]
        )
    }

    func testLiveAtomicWriterPropagatesDirectorySyncFailureAfterReplacingDestination() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LegacyMigrationDirectorySyncFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let destinationURL = rootURL.appendingPathComponent("history.jsonl")
        try Data("old".utf8).write(to: destinationURL)
        let fileSystem = FileManagerLegacyMigrationFileSystem(
            directorySyncOperations: LegacyMigrationDirectorySyncOperations(
                openDirectory: { path in
                    Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                },
                synchronize: { _ in
                    errno = EIO
                    return -1
                },
                close: { Darwin.close($0) }
            )
        )

        XCTAssertThrowsError(
            try fileSystem.writeDataAtomically(Data("new".utf8), to: destinationURL)
        ) { error in
            let writeError = error as? LegacyMigrationAtomicWriteError
            XCTAssertEqual(writeError?.destinationWasReplaced, true)
            XCTAssertEqual(writeError?.posixCode, EIO)
        }
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("new".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path),
            ["history.jsonl"]
        )
    }

    func testLiveAtomicWriterPropagatesDirectoryCloseFailureAfterReplacingDestination() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LegacyMigrationDirectoryCloseFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let destinationURL = rootURL.appendingPathComponent("history.jsonl")
        try Data("old".utf8).write(to: destinationURL)
        let closeFailure = FailingOnceDirectoryCloseOperation(errorCode: EIO)
        let fileSystem = FileManagerLegacyMigrationFileSystem(
            directorySyncOperations: LegacyMigrationDirectorySyncOperations(
                openDirectory: { path in
                    Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                },
                synchronize: { Darwin.fsync($0) },
                close: { closeFailure.close($0) }
            )
        )

        XCTAssertThrowsError(
            try fileSystem.writeDataAtomically(Data("new".utf8), to: destinationURL)
        ) { error in
            let writeError = error as? LegacyMigrationAtomicWriteError
            XCTAssertEqual(writeError?.destinationWasReplaced, true)
            XCTAssertEqual(writeError?.posixCode, EIO)
        }
        XCTAssertEqual(closeFailure.callCount, 1)
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("new".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path),
            ["history.jsonl"]
        )
    }

    func testPreferenceAttemptGuardRejectsSymlinkWithoutCapturingBaseline() throws {
        let fileSystem = MigrationTestFileSystem()
        let stateStore = MigrationTestStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fileSystem.setItemKind(.symbolicLink, at: fixture.preferenceAttemptGuardURL)
        try configureLegacySources(
            fixture,
            fileSystem: fileSystem,
            preferences: [InkletPreferenceKeys.interfaceLanguage: "legacy"]
        )

        let outcome = fixture.migrator.migrateAutomatically()

        assertIncomplete(outcome.results[.preferences], kind: .writeFailed)
        XCTAssertNil(stateStore.baseline)
        XCTAssertFalse(fileSystem.writeDataURLs.contains(fixture.preferenceAttemptGuardURL))
        XCTAssertNil(fixture.persistentDomain[InkletPreferenceKeys.interfaceLanguage])
    }

    private func makeMigrator(
        fileSystem: MigrationTestFileSystem,
        stateStore: MigrationTestStateStore,
        keychainClient: MigrationTestKeychainClient = MigrationTestKeychainClient(),
        lockTimeout: Duration = .milliseconds(100)
    ) -> MigratorTestFixture {
        let testBundleIdentifier = "com.example.inklet.tests.\(UUID().uuidString)"
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMigratorTests-home-\(UUID().uuidString)", isDirectory: true)
        let destinationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMigratorTests-destination-\(UUID().uuidString)", isDirectory: true)
        guard let defaults = UserDefaults(suiteName: testBundleIdentifier) else {
            preconditionFailure("Unable to open isolated test defaults")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: homeDirectory)
            try? FileManager.default.removeItem(at: destinationRoot)
            UserDefaults(suiteName: testBundleIdentifier)?.removePersistentDomain(
                forName: testBundleIdentifier
            )
        }
        let storagePaths = InkletStoragePaths(
            bundleIdentifier: testBundleIdentifier,
            applicationSupportRootURL: destinationRoot,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        let legacyRoot = LegacySandboxDataMigrator.expectedLegacyDataRoot(
            bundleIdentifier: testBundleIdentifier,
            homeDirectoryURL: homeDirectory
        )
        let preferencesURL = legacyRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(testBundleIdentifier).plist")
        let historyURL = legacyRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Inklet", isDirectory: true)
            .appendingPathComponent("history.jsonl")
        let lock = LegacyMigrationLock(
            fileURL: storagePaths.migrationLockFileURL,
            timeout: lockTimeout,
            retryInterval: .milliseconds(1)
        )
        let keychainFactory = MigrationTestKeychainFactory(client: keychainClient)
        let migrator = LegacySandboxDataMigrator(
            bundleIdentifier: testBundleIdentifier,
            storagePaths: storagePaths,
            homeDirectoryURL: homeDirectory,
            defaults: defaults,
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainStore: { providerID in
                keychainFactory.makeStore(providerID: providerID)
            },
            lock: lock
        )
        return MigratorTestFixture(
            migrator: migrator,
            bundleIdentifier: testBundleIdentifier,
            storagePaths: storagePaths,
            homeDirectoryURL: homeDirectory,
            defaults: defaults,
            keychainFactory: keychainFactory,
            legacyRoot: legacyRoot,
            preferencesURL: preferencesURL,
            historyURL: historyURL,
            lockURL: storagePaths.migrationLockFileURL
        )
    }

    private func configureLegacySources(
        _ fixture: MigratorTestFixture,
        fileSystem: MigrationTestFileSystem,
        preferences: [String: Any],
        history: Data? = nil
    ) throws {
        fileSystem.setItemKind(.directory, at: fixture.legacyRoot)
        try fileSystem.setPropertyList(preferences, at: fixture.preferencesURL)
        if let history {
            fileSystem.setData(history, at: fixture.historyURL)
        }
    }

    private func encodedHistory(_ items: [HistoryItem]) throws -> Data {
        try HistoryJSONLCodec.encode(items)
    }

    private func historyItem(
        idSuffix: Int,
        timestamp: TimeInterval,
        input: String
    ) -> HistoryItem {
        HistoryItem(
            id: UUID(
                uuidString: String(
                    format: "00000000-0000-0000-0000-%012d",
                    idSuffix
                )
            )!,
            createdAt: Date(timeIntervalSince1970: timestamp),
            source: .write,
            inputText: input,
            outputText: "output-\(input)",
            metadata: ["fixture": "history"]
        )
    }

    private func assertIncomplete(
        _ result: LegacyMigrationComponentResult?,
        kind: LegacyMigrationFailureKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .incomplete(failure)? = result else {
            return XCTFail("Expected incomplete result", file: file, line: line)
        }
        XCTAssertEqual(failure.kind, kind, file: file, line: line)
    }

    private func runDefaultsCommand(_ arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning && ContinuousClock.now < deadline {
            usleep(1_000)
        }
        guard !process.isRunning else {
            process.terminate()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}

private struct MigratorTestFixture {
    let migrator: LegacySandboxDataMigrator
    let bundleIdentifier: String
    let storagePaths: InkletStoragePaths
    let homeDirectoryURL: URL
    let defaults: UserDefaults
    let keychainFactory: MigrationTestKeychainFactory
    let legacyRoot: URL
    let preferencesURL: URL
    let historyURL: URL
    let lockURL: URL

    var historyDestinationURL: URL {
        storagePaths.historyFileURL
    }

    var preferenceAttemptGuardURL: URL {
        storagePaths.applicationSupportRootURL.appendingPathComponent(
            "legacy-migration.preference-baseline-attempted"
        )
    }

    var guardContents: Data {
        Data("Inklet legacy preference baseline verified v1\n\(bundleIdentifier)\n".utf8)
    }

    var attemptedGuardContents: Data {
        Data("Inklet legacy preference baseline attempted v1\n\(bundleIdentifier)\n".utf8)
    }

    var persistentDomain: [String: Any] {
        _ = defaults.synchronize()
        return defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
    }

    func makeFreshMigrator(
        fileSystem: MigrationTestFileSystem,
        stateStore: MigrationTestStateStore
    ) -> LegacySandboxDataMigrator {
        let factory = keychainFactory
        return LegacySandboxDataMigrator(
            bundleIdentifier: bundleIdentifier,
            storagePaths: storagePaths,
            homeDirectoryURL: homeDirectoryURL,
            defaults: defaults,
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainStore: { providerID in
                factory.makeStore(providerID: providerID)
            },
            lock: LegacyMigrationLock(
                fileURL: storagePaths.migrationLockFileURL,
                timeout: .milliseconds(100),
                retryInterval: .milliseconds(1)
            )
        )
    }
}

private final class MigrationTestFileSystem: LegacyMigrationFileSystem, @unchecked Sendable {
    private var itemKinds: [String: Result<LegacyMigrationItemKind, NSError>] = [:]
    private var storedData: [String: Data] = [:]
    private var readFailures: [String: NSError] = [:]
    private var writeFailures: [String: NSError] = [:]
    private var postReplacementWriteFailures: [String: [Int: NSError]] = [:]
    private var writeAttemptCounts: [String: Int] = [:]
    private(set) var itemKindURLs: [URL] = []
    private(set) var readDataURLs: [URL] = []
    private(set) var canonicalURLs: [URL] = []
    private(set) var createDirectoryURLs: [URL] = []
    private(set) var writeDataURLs: [URL] = []
    private(set) var successfulWriteURLs: [URL] = []

    var allURLs: [URL] {
        itemKindURLs
            + readDataURLs
            + canonicalURLs
            + createDirectoryURLs
            + writeDataURLs
    }

    func setItemKind(_ kind: LegacyMigrationItemKind, at url: URL) {
        itemKinds[url.standardizedFileURL.path] = .success(kind)
    }

    func failItemKind(at url: URL, with error: NSError) {
        itemKinds[url.standardizedFileURL.path] = .failure(error)
    }

    func setItemKindResult(
        _ result: Result<LegacyMigrationItemKind, NSError>,
        at url: URL
    ) {
        itemKinds[url.standardizedFileURL.path] = result
    }

    func setData(_ data: Data, at url: URL) {
        let standardizedURL = url.standardizedFileURL
        storedData[standardizedURL.path] = data
        itemKinds[standardizedURL.path] = .success(.regularFile)
    }

    func setPropertyList(_ dictionary: [String: Any], at url: URL) throws {
        setData(
            try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: .binary,
                options: 0
            ),
            at: url
        )
    }

    func data(at url: URL) -> Data? {
        storedData[url.standardizedFileURL.path]
    }

    func failRead(at url: URL, with error: NSError) {
        readFailures[url.standardizedFileURL.path] = error
    }

    func failWrite(at url: URL, with error: NSError) {
        writeFailures[url.standardizedFileURL.path] = error
    }

    func failWriteAfterReplacing(
        at url: URL,
        onAttempt attempt: Int,
        with error: NSError
    ) {
        postReplacementWriteFailures[url.standardizedFileURL.path, default: [:]][attempt] = error
    }

    func itemKind(at url: URL) throws -> LegacyMigrationItemKind {
        let standardizedURL = url.standardizedFileURL
        itemKindURLs.append(standardizedURL)
        guard let result = itemKinds[standardizedURL.path] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        return try result.get()
    }

    func readData(at url: URL) throws -> Data {
        let standardizedURL = url.standardizedFileURL
        readDataURLs.append(standardizedURL)
        if let error = readFailures[standardizedURL.path] {
            throw error
        }
        guard let data = storedData[standardizedURL.path] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        return data
    }

    func createDirectory(at url: URL) throws {
        createDirectoryURLs.append(url.standardizedFileURL)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        let standardizedURL = url.standardizedFileURL
        writeDataURLs.append(standardizedURL)
        let attempt = writeAttemptCounts[standardizedURL.path, default: 0] + 1
        writeAttemptCounts[standardizedURL.path] = attempt
        if let error = writeFailures[standardizedURL.path] {
            throw error
        }
        storedData[standardizedURL.path] = data
        itemKinds[standardizedURL.path] = .success(.regularFile)
        successfulWriteURLs.append(standardizedURL)
        if let error = postReplacementWriteFailures[standardizedURL.path]?[attempt] {
            let posixCode = error.domain == NSPOSIXErrorDomain ? Int32(error.code) : EIO
            throw LegacyMigrationAtomicWriteError(
                destinationWasReplaced: true,
                posixCode: posixCode
            )
        }
    }

    func canonicalURL(for url: URL) throws -> URL {
        canonicalURLs.append(url.standardizedFileURL)
        return url.standardizedFileURL
    }
}

private final class MigrationTestStateStore: LegacyMigrationStateStore, @unchecked Sendable {
    var versions: [LegacyMigrationComponent: Int] = [:]
    var baseline: [String: PreferenceFingerprint]?
    var failSetBaseline = false
    var failReadBaseline = false
    var failBaselineReadAfterSet = false
    var markerFailures: Set<LegacyMigrationComponent> = []
    private(set) var reloadCount = 0
    private(set) var setVersionCalls: [LegacyMigrationComponent] = []
    private var didSetBaseline = false

    func reload() throws {
        reloadCount += 1
    }

    func completedVersion(for component: LegacyMigrationComponent) throws -> Int? {
        versions[component]
    }

    func setCompletedVersion(_ version: Int, for component: LegacyMigrationComponent) throws {
        setVersionCalls.append(component)
        if markerFailures.contains(component) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        versions[component] = version
    }

    func preferenceBaseline() throws -> [String: PreferenceFingerprint]? {
        if failReadBaseline || (failBaselineReadAfterSet && didSetBaseline) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return baseline
    }

    func setPreferenceBaseline(_ baseline: [String: PreferenceFingerprint]) throws {
        if failSetBaseline {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        self.baseline = baseline
        didSetBaseline = true
    }
}

private final class MigrationTestKeychainFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let client: MigrationTestKeychainClient
    private var recordedProviderIDs: [String] = []

    init(client: MigrationTestKeychainClient) {
        self.client = client
    }

    var providerIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedProviderIDs
    }

    func makeStore(providerID: String) -> KeychainStore {
        lock.lock()
        recordedProviderIDs.append(providerID)
        lock.unlock()
        return KeychainStore(
            service: "Inklet.MigrationTests",
            account: providerID,
            client: client
        )
    }
}

private final class MigrationTestKeychainClient: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var saveCounts: [String: Int] = [:]
    private var updateCounts: [String: Int] = [:]
    private var addCounts: [String: Int] = [:]
    private var valuesInsertedBeforeAdd: [String: String] = [:]
    var loadFailureAccounts: Set<String> = []
    var saveFailureAccounts: Set<String> = []

    init(values: [String: String] = [:]) {
        self.values = values
    }

    var allValues: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func value(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func saveCount(for account: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return saveCounts[account, default: 0]
    }

    func updateCount(for account: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return updateCounts[account, default: 0]
    }

    func addCount(for account: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return addCounts[account, default: 0]
    }

    func insertBeforeNextAdd(_ value: String, for account: String) {
        lock.lock()
        valuesInsertedBeforeAdd[account] = value
        lock.unlock()
    }

    func copyMatching(
        _ query: [String: Any],
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let account = account(from: query) else { return errSecParam }
        if loadFailureAccounts.contains(account) {
            return errSecInteractionNotAllowed
        }
        guard let value = values[account] else { return errSecItemNotFound }
        result?.pointee = Data(value.utf8) as CFData
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let account = account(from: query) else { return errSecParam }
        updateCounts[account, default: 0] += 1
        if saveFailureAccounts.contains(account) { return errSecAuthFailed }
        guard values[account] != nil else { return errSecItemNotFound }
        guard let data = attributes[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return errSecParam
        }
        values[account] = value
        saveCounts[account, default: 0] += 1
        return errSecSuccess
    }

    func add(
        _ query: [String: Any],
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let account = account(from: query) else { return errSecParam }
        addCounts[account, default: 0] += 1
        if saveFailureAccounts.contains(account) { return errSecAuthFailed }
        if let concurrentValue = valuesInsertedBeforeAdd.removeValue(forKey: account) {
            values[account] = concurrentValue
        }
        guard values[account] == nil else { return errSecDuplicateItem }
        guard let data = query[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return errSecParam
        }
        values[account] = value
        saveCounts[account, default: 0] += 1
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let account = account(from: query) else { return errSecParam }
        values.removeValue(forKey: account)
        return errSecSuccess
    }

    private func account(from query: [String: Any]) -> String? {
        query[kSecAttrAccount as String] as? String
    }
}

private final class FailingFirstSynchronizationUserDefaults: UserDefaults {
    private var synchronizationCount = 0

    override func synchronize() -> Bool {
        synchronizationCount += 1
        if synchronizationCount == 1 { return false }
        return super.synchronize()
    }
}

private final class FixedLegacyMigrationUserDefaultsFactory: @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }
}

private final class SequencedLegacyMigrationUserDefaultsFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: [UserDefaults]
    private var index = 0

    init(defaults: [UserDefaults]) {
        precondition(!defaults.isEmpty)
        self.defaults = defaults
    }

    func next() -> UserDefaults {
        lock.lock()
        defer { lock.unlock() }
        let defaults = defaults[min(index, defaults.count - 1)]
        index += 1
        return defaults
    }
}

private final class LegacyMigrationDefaultsResolverRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let domainName: String
    private let writerDefaults: UserDefaults
    private var currentWriterCallCount = 0
    private var freshCurrentCallCount = 0
    private var suiteCallCount = 0

    init(domainName: String, writerDefaults: UserDefaults) {
        self.domainName = domainName
        self.writerDefaults = writerDefaults
    }

    var currentWriterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentWriterCallCount
    }

    var freshCurrentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return freshCurrentCallCount
    }

    var suiteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return suiteCallCount
    }

    func currentWriter() -> UserDefaults {
        lock.lock()
        currentWriterCallCount += 1
        lock.unlock()
        return writerDefaults
    }

    func freshCurrent() -> UserDefaults {
        lock.lock()
        freshCurrentCallCount += 1
        lock.unlock()
        guard let defaults = UserDefaults(suiteName: domainName) else {
            preconditionFailure("Unable to open isolated current-domain test defaults")
        }
        return defaults
    }

    func suite(named requestedDomainName: String) -> UserDefaults? {
        lock.lock()
        suiteCallCount += 1
        lock.unlock()
        return UserDefaults(suiteName: requestedDomainName)
    }
}

private final class FailingOnceDirectoryCloseOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let errorCode: Int32
    private var calls = 0

    init(errorCode: Int32) {
        self.errorCode = errorCode
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func close(_ descriptor: Int32) -> Int32 {
        let closeResult = Darwin.close(descriptor)
        lock.lock()
        calls += 1
        let shouldFail = calls == 1
        lock.unlock()
        if shouldFail {
            errno = errorCode
            return -1
        }
        return closeResult
    }
}

private final class EmptyPersistentDomainUserDefaults: UserDefaults {
    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        [:]
    }
}
