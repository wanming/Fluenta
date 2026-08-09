import Darwin
import Foundation
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
        XCTAssertEqual(
            fileSystem.itemKindURLs,
            [fixture.legacyRoot, fixture.preferencesURL, fixture.historyURL]
        )
        XCTAssertTrue(fileSystem.readDataURLs.isEmpty)
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

    private func makeMigrator(
        fileSystem: MigrationTestFileSystem,
        stateStore: MigrationTestStateStore,
        lockTimeout: Duration = .milliseconds(100)
    ) -> MigratorTestFixture {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMigratorTests-home-\(UUID().uuidString)", isDirectory: true)
        let destinationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMigratorTests-destination-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: homeDirectory)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let storagePaths = InkletStoragePaths(
            bundleIdentifier: bundleIdentifier,
            applicationSupportRootURL: destinationRoot,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        let legacyRoot = LegacySandboxDataMigrator.expectedLegacyDataRoot(
            bundleIdentifier: bundleIdentifier,
            homeDirectoryURL: homeDirectory
        )
        let preferencesURL = legacyRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist")
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
        let migrator = LegacySandboxDataMigrator(
            bundleIdentifier: bundleIdentifier,
            storagePaths: storagePaths,
            homeDirectoryURL: homeDirectory,
            defaults: .standard,
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainStore: { _ in KeychainStore() },
            lock: lock
        )
        return MigratorTestFixture(
            migrator: migrator,
            legacyRoot: legacyRoot,
            preferencesURL: preferencesURL,
            historyURL: historyURL,
            lockURL: storagePaths.migrationLockFileURL
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
    let legacyRoot: URL
    let preferencesURL: URL
    let historyURL: URL
    let lockURL: URL
}

private final class MigrationTestFileSystem: LegacyMigrationFileSystem, @unchecked Sendable {
    private var itemKinds: [String: Result<LegacyMigrationItemKind, NSError>] = [:]
    private(set) var itemKindURLs: [URL] = []
    private(set) var readDataURLs: [URL] = []
    private(set) var canonicalURLs: [URL] = []

    var allURLs: [URL] {
        itemKindURLs + readDataURLs + canonicalURLs
    }

    func setItemKind(_ kind: LegacyMigrationItemKind, at url: URL) {
        itemKinds[url.standardizedFileURL.path] = .success(kind)
    }

    func failItemKind(at url: URL, with error: NSError) {
        itemKinds[url.standardizedFileURL.path] = .failure(error)
    }

    func itemKind(at url: URL) throws -> LegacyMigrationItemKind {
        itemKindURLs.append(url.standardizedFileURL)
        guard let result = itemKinds[url.standardizedFileURL.path] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return try result.get()
    }

    func readData(at url: URL) throws -> Data {
        readDataURLs.append(url.standardizedFileURL)
        return Data()
    }

    func createDirectory(at url: URL) throws {}

    func writeDataAtomically(_ data: Data, to url: URL) throws {}

    func canonicalURL(for url: URL) throws -> URL {
        canonicalURLs.append(url.standardizedFileURL)
        return url.standardizedFileURL
    }
}

private final class MigrationTestStateStore: LegacyMigrationStateStore, @unchecked Sendable {
    var versions: [LegacyMigrationComponent: Int] = [:]
    var baseline: [String: PreferenceFingerprint]?
    private(set) var reloadCount = 0

    func reload() throws {
        reloadCount += 1
    }

    func completedVersion(for component: LegacyMigrationComponent) throws -> Int? {
        versions[component]
    }

    func setCompletedVersion(_ version: Int, for component: LegacyMigrationComponent) throws {
        versions[component] = version
    }

    func preferenceBaseline() throws -> [String: PreferenceFingerprint]? {
        baseline
    }

    func setPreferenceBaseline(_ baseline: [String: PreferenceFingerprint]) throws {
        self.baseline = baseline
    }
}

private final class FailingFirstSynchronizationUserDefaults: UserDefaults, @unchecked Sendable {
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

private final class EmptyPersistentDomainUserDefaults: UserDefaults, @unchecked Sendable {
    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        [:]
    }
}
