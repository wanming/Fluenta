import Darwin
import Foundation
import XCTest
@testable import InkletCore

final class LegacyMigrationSourceValidationTests: XCTestCase {
    private let bundleIdentifier = "com.example.inklet.tests.\(UUID().uuidString)"

    func testLiveFileSystemReportsSymlinkWithoutFollowingIt() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyFileSystemTests-\(UUID().uuidString)", isDirectory: true)
        let targetURL = directoryURL.appendingPathComponent("target")
        let symlinkURL = directoryURL.appendingPathComponent("link")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let fileSystem = FileManagerLegacyMigrationFileSystem()

        XCTAssertEqual(try fileSystem.itemKind(at: targetURL), .regularFile)
        XCTAssertEqual(try fileSystem.itemKind(at: symlinkURL), .symbolicLink)
        XCTAssertEqual(
            try fileSystem.canonicalURL(for: symlinkURL),
            targetURL.standardizedFileURL
        )
    }

    func testLiveUserSelectedValidationAcceptsOnlyExactCanonicalBundleDataRoot() throws {
        for bundleIdentifier in [
            InkletStoragePaths.productionBundleIdentifier,
            InkletStoragePaths.localBundleIdentifier,
        ] {
            let fixture = try makeLiveValidationFixture(bundleIdentifier: bundleIdentifier)

            XCTAssertEqual(
                try fixture.migrator.validateUserSelectedDataRoot(fixture.legacyRoot),
                fixture.legacyRoot.standardizedFileURL
            )

            let otherBundleIdentifier = bundleIdentifier == InkletStoragePaths.productionBundleIdentifier
                ? InkletStoragePaths.localBundleIdentifier
                : InkletStoragePaths.productionBundleIdentifier
            let otherRoot = LegacySandboxDataMigrator.expectedLegacyDataRoot(
                bundleIdentifier: otherBundleIdentifier,
                homeDirectoryURL: fixture.homeDirectory
            )
            try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
            try writeEmptyPreferences(root: otherRoot, bundleIdentifier: otherBundleIdentifier)

            XCTAssertThrowsError(try fixture.migrator.validateUserSelectedDataRoot(otherRoot)) {
                XCTAssertEqual(($0 as? LegacyMigrationFailure)?.kind, .invalidSource)
            }

            let lookalike = fixture.legacyRoot
                .deletingLastPathComponent()
                .appendingPathComponent("Data-copy", isDirectory: true)
            try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
            try writeEmptyPreferences(root: lookalike, bundleIdentifier: bundleIdentifier)
            XCTAssertThrowsError(try fixture.migrator.validateUserSelectedDataRoot(lookalike)) {
                XCTAssertEqual(($0 as? LegacyMigrationFailure)?.kind, .invalidSource)
            }

            let symlink = fixture.legacyRoot
                .deletingLastPathComponent()
                .appendingPathComponent("Data-link", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.legacyRoot)
            XCTAssertThrowsError(try fixture.migrator.validateUserSelectedDataRoot(symlink)) {
                XCTAssertEqual(($0 as? LegacyMigrationFailure)?.kind, .invalidSource)
            }
        }
    }

    func testLiveUserSelectedValidationRequiresExactBundlePreferencesFile() throws {
        let missingFixture = try makeLiveValidationFixture(
            bundleIdentifier: InkletStoragePaths.productionBundleIdentifier,
            createPreferencesFile: false
        )
        XCTAssertThrowsError(
            try missingFixture.migrator.validateUserSelectedDataRoot(missingFixture.legacyRoot)
        ) {
            XCTAssertEqual(($0 as? LegacyMigrationFailure)?.kind, .invalidSource)
        }

        let wrongFixture = try makeLiveValidationFixture(
            bundleIdentifier: InkletStoragePaths.localBundleIdentifier,
            createPreferencesFile: false
        )
        try writeEmptyPreferences(
            root: wrongFixture.legacyRoot,
            bundleIdentifier: InkletStoragePaths.productionBundleIdentifier
        )
        XCTAssertThrowsError(
            try wrongFixture.migrator.validateUserSelectedDataRoot(wrongFixture.legacyRoot)
        ) {
            XCTAssertEqual(($0 as? LegacyMigrationFailure)?.kind, .invalidSource)
        }
    }

    func testOnlyConfirmedPOSIXENOENTMeansTheContainerIsMissing() throws {
        let missingErrors = [
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [
                    NSUnderlyingErrorKey: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(ENOENT)
                    )
                ]
            ),
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadNoSuchFileError,
                userInfo: [
                    NSUnderlyingErrorKey: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(ENOENT)
                    )
                ]
            ),
        ]

        for missingError in missingErrors {
            let fileSystem = FakeLegacyMigrationFileSystem()
            let stateStore = InMemoryLegacyMigrationStateStore()
            let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
            fileSystem.setItemKindFailure(missingError, at: fixture.legacyRoot)

            let outcome = fixture.migrator.migrateAutomatically()

            assertEveryComponent(in: outcome, equals: .noLegacyData)
        }

        for cocoaCode in [NSFileNoSuchFileError, NSFileReadNoSuchFileError] {
            let fileSystem = FakeLegacyMigrationFileSystem()
            let stateStore = InMemoryLegacyMigrationStateStore()
            let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
            fileSystem.setItemKindFailure(
                NSError(domain: NSCocoaErrorDomain, code: cocoaCode),
                at: fixture.legacyRoot
            )

            let outcome = fixture.migrator.migrateAutomatically()

            assertEveryIncompleteComponent(in: outcome, hasKind: .indeterminateLookup)
        }

        let wrappedFileSystem = FakeLegacyMigrationFileSystem()
        let wrappedFixture = makeMigrator(
            fileSystem: wrappedFileSystem,
            stateStore: InMemoryLegacyMigrationStateStore()
        )
        wrappedFileSystem.setItemKindFailure(
            NSError(
                domain: "LegacyMigrationSourceValidationTests",
                code: 1,
                userInfo: [
                    NSUnderlyingErrorKey: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(ENOENT)
                    )
                ]
            ),
            at: wrappedFixture.legacyRoot
        )

        let wrappedOutcome = wrappedFixture.migrator.migrateAutomatically()

        assertEveryIncompleteComponent(in: wrappedOutcome, hasKind: .indeterminateLookup)

        let unrelatedCocoaFileSystem = FakeLegacyMigrationFileSystem()
        let unrelatedCocoaFixture = makeMigrator(
            fileSystem: unrelatedCocoaFileSystem,
            stateStore: InMemoryLegacyMigrationStateStore()
        )
        unrelatedCocoaFileSystem.setItemKindFailure(
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [
                    NSUnderlyingErrorKey: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(ENOENT)
                    )
                ]
            ),
            at: unrelatedCocoaFixture.legacyRoot
        )

        let unrelatedCocoaOutcome = unrelatedCocoaFixture.migrator.migrateAutomatically()

        assertEveryIncompleteComponent(
            in: unrelatedCocoaOutcome,
            hasKind: .indeterminateLookup
        )
    }

    func testPermissionLookupErrorsRemainPermissionDenied() {
        let permissionErrors = [
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
        ]

        for permissionError in permissionErrors {
            let fileSystem = FakeLegacyMigrationFileSystem()
            let stateStore = InMemoryLegacyMigrationStateStore()
            let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
            fileSystem.setItemKindFailure(permissionError, at: fixture.legacyRoot)

            let outcome = fixture.migrator.migrateAutomatically()

            assertEveryIncompleteComponent(in: outcome, hasKind: .permissionDenied)
            XCTAssertTrue(outcome.shouldOfferAssistedImport)
        }
    }

    func testUnexpectedLookupErrorIsIndeterminateAndContainsNoAbsolutePath() throws {
        let fileSystem = FakeLegacyMigrationFileSystem()
        let stateStore = InMemoryLegacyMigrationStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        fileSystem.setItemKindFailure(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
            at: fixture.legacyRoot
        )

        let outcome = fixture.migrator.migrateAutomatically()

        assertEveryIncompleteComponent(in: outcome, hasKind: .indeterminateLookup)
        for component in LegacyMigrationComponent.allCases {
            let failure = try XCTUnwrap(incompleteFailure(outcome.results[component]))
            XCTAssertEqual(failure.sourceLabel, "legacy/container")
            XCTAssertFalse(failure.nonSensitiveDescription.contains(fixture.homeDirectory.path))
            XCTAssertFalse(failure.nonSensitiveDescription.contains("/Users/"))
        }
    }

    func testSymlinkContainerAndWrongSourceTypesAreInvalid() {
        let symlinkFileSystem = FakeLegacyMigrationFileSystem()
        let symlinkFixture = makeMigrator(
            fileSystem: symlinkFileSystem,
            stateStore: InMemoryLegacyMigrationStateStore()
        )
        symlinkFileSystem.setItemKind(.symbolicLink, at: symlinkFixture.legacyRoot)

        let symlinkOutcome = symlinkFixture.migrator.migrateAutomatically()

        assertEveryIncompleteComponent(in: symlinkOutcome, hasKind: .invalidSource)
        XCTAssertFalse(symlinkOutcome.shouldOfferAssistedImport)

        let wrongTypeFileSystem = FakeLegacyMigrationFileSystem()
        let wrongTypeFixture = makeMigrator(
            fileSystem: wrongTypeFileSystem,
            stateStore: InMemoryLegacyMigrationStateStore()
        )
        wrongTypeFileSystem.setItemKind(.directory, at: wrongTypeFixture.legacyRoot)
        wrongTypeFileSystem.setItemKind(.directory, at: wrongTypeFixture.preferencesURL)
        wrongTypeFileSystem.setItemKind(.other, at: wrongTypeFixture.historyURL)

        let wrongTypeOutcome = wrongTypeFixture.migrator.migrateAutomatically()

        assertIncomplete(wrongTypeOutcome.results[.preferences], hasKind: .invalidSource)
        assertIncomplete(wrongTypeOutcome.results[.credentials], hasKind: .invalidSource)
        assertIncomplete(wrongTypeOutcome.results[.history], hasKind: .invalidSource)
        XCTAssertFalse(
            wrongTypeFileSystem.readDataURLs.contains {
                $0.path.hasPrefix(wrongTypeFixture.legacyRoot.path + "/")
            }
        )
    }

    func testUserSelectedValidationRejectsCanonicalMismatchBeforeReadingContent() {
        let fileSystem = FakeLegacyMigrationFileSystem()
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: InMemoryLegacyMigrationStateStore()
        )
        let lookalikeURL = fixture.legacyRoot
            .deletingLastPathComponent()
            .appendingPathComponent("Data-lookalike", isDirectory: true)
        fileSystem.setCanonicalURL(fixture.legacyRoot, for: lookalikeURL)

        XCTAssertThrowsError(
            try fixture.migrator.validateUserSelectedDataRoot(lookalikeURL)
        ) { error in
            let failure = error as? LegacyMigrationFailure
            XCTAssertEqual(failure?.kind, .invalidSource)
            XCTAssertEqual(failure?.sourceLabel, "legacy/container")
        }
        XCTAssertTrue(fileSystem.readDataURLs.isEmpty)
        XCTAssertTrue(fileSystem.itemKindURLs.isEmpty)
    }

    func testUserSelectedCanonicalLookupClassifiesMissingPermissionAndUnknown() {
        let cases: [(NSError, LegacyMigrationFailureKind)] = [
            (
                NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
                .invalidSource
            ),
            (
                NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                .permissionDenied
            ),
            (
                NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
                .indeterminateLookup
            ),
        ]

        for (lookupError, expectedKind) in cases {
            let fileSystem = FakeLegacyMigrationFileSystem()
            let fixture = makeMigrator(
                fileSystem: fileSystem,
                stateStore: InMemoryLegacyMigrationStateStore()
            )
            fileSystem.setCanonicalURLFailure(lookupError, for: fixture.legacyRoot)

            XCTAssertThrowsError(
                try fixture.migrator.validateUserSelectedDataRoot(fixture.legacyRoot)
            ) { error in
                XCTAssertEqual((error as? LegacyMigrationFailure)?.kind, expectedKind)
            }
            XCTAssertTrue(fileSystem.itemKindURLs.isEmpty)
            XCTAssertTrue(fileSystem.readDataURLs.isEmpty)
        }
    }

    func testUserSelectedValidationTreatsMissingExpectedCanonicalRootAsInvalidSource() {
        let fileSystem = FakeLegacyMigrationFileSystem()
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: InMemoryLegacyMigrationStateStore()
        )
        fileSystem.setCanonicalURLResults(
            [
                .success(fixture.legacyRoot),
                .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))),
            ],
            for: fixture.legacyRoot
        )

        XCTAssertThrowsError(
            try fixture.migrator.validateUserSelectedDataRoot(fixture.legacyRoot)
        ) { error in
            XCTAssertEqual((error as? LegacyMigrationFailure)?.kind, .invalidSource)
        }
        XCTAssertTrue(fileSystem.itemKindURLs.isEmpty)
        XCTAssertTrue(fileSystem.readDataURLs.isEmpty)
    }

    func testUserSelectedValidationRequiresExactRealRootAndRegularPreferencesFile() throws {
        let fileSystem = FakeLegacyMigrationFileSystem()
        let fixture = makeMigrator(
            fileSystem: fileSystem,
            stateStore: InMemoryLegacyMigrationStateStore()
        )
        fileSystem.setItemKind(.directory, at: fixture.legacyRoot)
        fileSystem.setItemKind(.regularFile, at: fixture.preferencesURL)

        let validatedURL = try fixture.migrator.validateUserSelectedDataRoot(fixture.legacyRoot)

        XCTAssertEqual(validatedURL, fixture.legacyRoot.standardizedFileURL)
        XCTAssertEqual(fileSystem.itemKindURLs, [fixture.legacyRoot, fixture.preferencesURL])
        XCTAssertTrue(fileSystem.readDataURLs.isEmpty)

        let invalidFileSystem = FakeLegacyMigrationFileSystem()
        let invalidFixture = makeMigrator(
            fileSystem: invalidFileSystem,
            stateStore: InMemoryLegacyMigrationStateStore()
        )
        invalidFileSystem.setItemKind(.directory, at: invalidFixture.legacyRoot)
        invalidFileSystem.setItemKind(.symbolicLink, at: invalidFixture.preferencesURL)

        XCTAssertThrowsError(
            try invalidFixture.migrator.validateUserSelectedDataRoot(invalidFixture.legacyRoot)
        ) { error in
            XCTAssertEqual((error as? LegacyMigrationFailure)?.kind, .invalidSource)
        }
        XCTAssertTrue(invalidFileSystem.readDataURLs.isEmpty)
    }

    func testUserSelectedValidationPreservesPreferencesLookupFailures() {
        let cases: [(NSError, LegacyMigrationFailureKind)] = [
            (
                NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                .permissionDenied
            ),
            (
                NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
                .indeterminateLookup
            ),
        ]

        for (lookupError, expectedKind) in cases {
            let fileSystem = FakeLegacyMigrationFileSystem()
            let fixture = makeMigrator(
                fileSystem: fileSystem,
                stateStore: InMemoryLegacyMigrationStateStore()
            )
            fileSystem.setItemKind(.directory, at: fixture.legacyRoot)
            fileSystem.setItemKindFailure(lookupError, at: fixture.preferencesURL)

            XCTAssertThrowsError(
                try fixture.migrator.validateUserSelectedDataRoot(fixture.legacyRoot)
            ) { error in
                let failure = error as? LegacyMigrationFailure
                XCTAssertEqual(failure?.kind, expectedKind)
                XCTAssertEqual(
                    failure?.sourceLabel,
                    "legacy/Library/Preferences/\(bundleIdentifier).plist"
                )
            }
            XCTAssertTrue(fileSystem.readDataURLs.isEmpty)
        }
    }

    func testPresentValidatedSourcesAreReadAndMigratedInTaskFour() throws {
        let fileSystem = FakeLegacyMigrationFileSystem()
        let stateStore = InMemoryLegacyMigrationStateStore()
        let fixture = makeMigrator(fileSystem: fileSystem, stateStore: stateStore)
        let historyItem = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            createdAt: Date(timeIntervalSince1970: 10),
            source: .write,
            inputText: "legacy-input",
            outputText: "legacy-output"
        )
        fileSystem.setItemKind(.directory, at: fixture.legacyRoot)
        fileSystem.setData(
            try PropertyListSerialization.data(
                fromPropertyList: [InkletPreferenceKeys.interfaceLanguage: "zh-CN"],
                format: .binary,
                options: 0
            ),
            at: fixture.preferencesURL
        )
        let legacyHistoryData = try HistoryJSONLCodec.encode([historyItem])
        fileSystem.setData(legacyHistoryData, at: fixture.historyURL)

        let outcome = fixture.migrator.migrateAutomatically()

        XCTAssertEqual(outcome.results[.preferences], .completed(changedDestination: true))
        XCTAssertEqual(outcome.results[.credentials], .completed(changedDestination: false))
        XCTAssertEqual(outcome.results[.history], .completed(changedDestination: true))
        XCTAssertEqual(stateStore.versions[.preferences], 1)
        XCTAssertEqual(stateStore.versions[.credentials], 1)
        XCTAssertEqual(stateStore.versions[.history], 1)
        XCTAssertTrue(fileSystem.readDataURLs.contains(fixture.preferencesURL))
        XCTAssertTrue(fileSystem.readDataURLs.contains(fixture.historyURL))
        XCTAssertEqual(fileSystem.data(at: fixture.historyURL), legacyHistoryData)
        XCTAssertFalse(
            fileSystem.readDataURLs.contains { $0.path.contains("selection-translation-cache") }
        )
    }

    private func makeMigrator(
        fileSystem: FakeLegacyMigrationFileSystem,
        stateStore: InMemoryLegacyMigrationStateStore
    ) -> MigrationFixture {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacySourceTests-home-\(UUID().uuidString)", isDirectory: true)
        let destinationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacySourceTests-destination-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: homeDirectory)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let storagePaths = InkletStoragePaths(
            bundleIdentifier: bundleIdentifier,
            applicationSupportRootURL: destinationRoot,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        let missingError = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        fileSystem.setItemKindFailure(
            missingError,
            at: storagePaths.applicationSupportRootURL.appendingPathComponent(
                "legacy-migration.preference-baseline-attempted"
            )
        )
        fileSystem.setItemKindFailure(missingError, at: storagePaths.historyFileURL)
        let defaultsDomainName = bundleIdentifier
        guard let defaults = UserDefaults(suiteName: defaultsDomainName) else {
            preconditionFailure("Unable to open source-validation test defaults")
        }
        defaults.removePersistentDomain(forName: defaultsDomainName)
        addTeardownBlock {
            UserDefaults(suiteName: defaultsDomainName)?.removePersistentDomain(
                forName: defaultsDomainName
            )
        }
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
        let migrator = LegacySandboxDataMigrator(
            bundleIdentifier: bundleIdentifier,
            storagePaths: storagePaths,
            homeDirectoryURL: homeDirectory,
            defaults: defaults,
            fileSystem: fileSystem,
            stateStore: stateStore,
            keychainStore: { _ in KeychainStore() },
            lock: LegacyMigrationLock(
                fileURL: storagePaths.migrationLockFileURL,
                timeout: .milliseconds(100),
                retryInterval: .milliseconds(1)
            )
        )
        return MigrationFixture(
            migrator: migrator,
            homeDirectory: homeDirectory,
            legacyRoot: legacyRoot,
            preferencesURL: preferencesURL,
            historyURL: historyURL
        )
    }

    private func makeLiveValidationFixture(
        bundleIdentifier: String,
        createPreferencesFile: Bool = true
    ) throws -> LiveValidationFixture {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyLiveValidation-home-\(UUID().uuidString)", isDirectory: true)
        let destinationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyLiveValidation-destination-\(UUID().uuidString)", isDirectory: true)
        let legacyRoot = LegacySandboxDataMigrator.expectedLegacyDataRoot(
            bundleIdentifier: bundleIdentifier,
            homeDirectoryURL: homeDirectory
        )
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        if createPreferencesFile {
            try writeEmptyPreferences(root: legacyRoot, bundleIdentifier: bundleIdentifier)
        } else {
            try FileManager.default.createDirectory(
                at: legacyRoot
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Preferences", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: homeDirectory)
            try? FileManager.default.removeItem(at: destinationRoot)
        }

        let storagePaths = InkletStoragePaths(
            bundleIdentifier: bundleIdentifier,
            applicationSupportRootURL: destinationRoot,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        let domainName = "\(bundleIdentifier).validation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domainName))
        defaults.removePersistentDomain(forName: domainName)
        addTeardownBlock {
            UserDefaults(suiteName: domainName)?.removePersistentDomain(forName: domainName)
        }
        let migrator = LegacySandboxDataMigrator(
            bundleIdentifier: bundleIdentifier,
            storagePaths: storagePaths,
            homeDirectoryURL: homeDirectory,
            defaults: defaults,
            fileSystem: FileManagerLegacyMigrationFileSystem(),
            stateStore: InMemoryLegacyMigrationStateStore(),
            keychainStore: { _ in KeychainStore() },
            lock: LegacyMigrationLock(fileURL: storagePaths.migrationLockFileURL)
        )
        return LiveValidationFixture(
            migrator: migrator,
            homeDirectory: homeDirectory,
            legacyRoot: legacyRoot
        )
    }

    private func preferencesURL(root: URL, bundleIdentifier: String) -> URL {
        root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    private func writeEmptyPreferences(root: URL, bundleIdentifier: String) throws {
        let url = preferencesURL(root: root, bundleIdentifier: bundleIdentifier)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }

    private func assertEveryComponent(
        in outcome: LegacySandboxMigrationOutcome,
        equals expected: LegacyMigrationComponentResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for component in LegacyMigrationComponent.allCases {
            XCTAssertEqual(outcome.results[component], expected, file: file, line: line)
        }
    }

    private func assertEveryIncompleteComponent(
        in outcome: LegacySandboxMigrationOutcome,
        hasKind expectedKind: LegacyMigrationFailureKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for component in LegacyMigrationComponent.allCases {
            assertIncomplete(
                outcome.results[component],
                hasKind: expectedKind,
                file: file,
                line: line
            )
        }
    }

    private func assertIncomplete(
        _ result: LegacyMigrationComponentResult?,
        hasKind expectedKind: LegacyMigrationFailureKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(incompleteFailure(result)?.kind, expectedKind, file: file, line: line)
    }

    private func incompleteFailure(
        _ result: LegacyMigrationComponentResult?
    ) -> LegacyMigrationFailure? {
        guard case let .incomplete(failure)? = result else { return nil }
        return failure
    }
}

private struct MigrationFixture {
    let migrator: LegacySandboxDataMigrator
    let homeDirectory: URL
    let legacyRoot: URL
    let preferencesURL: URL
    let historyURL: URL
}

private struct LiveValidationFixture {
    let migrator: LegacySandboxDataMigrator
    let homeDirectory: URL
    let legacyRoot: URL
}

private final class FakeLegacyMigrationFileSystem: LegacyMigrationFileSystem, @unchecked Sendable {
    private var itemKinds: [String: Result<LegacyMigrationItemKind, NSError>] = [:]
    private var canonicalURLResults: [String: [Result<URL, NSError>]] = [:]
    private var storedData: [String: Data] = [:]

    private(set) var itemKindURLs: [URL] = []
    private(set) var readDataURLs: [URL] = []

    func setItemKind(_ kind: LegacyMigrationItemKind, at url: URL) {
        itemKinds[url.standardizedFileURL.path] = .success(kind)
    }

    func setItemKindFailure(_ error: NSError, at url: URL) {
        itemKinds[url.standardizedFileURL.path] = .failure(error)
    }

    func setData(_ data: Data, at url: URL) {
        let standardizedURL = url.standardizedFileURL
        storedData[standardizedURL.path] = data
        itemKinds[standardizedURL.path] = .success(.regularFile)
    }

    func data(at url: URL) -> Data? {
        storedData[url.standardizedFileURL.path]
    }

    func setCanonicalURL(_ canonicalURL: URL, for url: URL) {
        setCanonicalURLResults([.success(canonicalURL.standardizedFileURL)], for: url)
    }

    func setCanonicalURLFailure(_ error: NSError, for url: URL) {
        setCanonicalURLResults([.failure(error)], for: url)
    }

    func setCanonicalURLResults(
        _ results: [Result<URL, NSError>],
        for url: URL
    ) {
        canonicalURLResults[url.standardizedFileURL.path] = results
    }

    func itemKind(at url: URL) throws -> LegacyMigrationItemKind {
        itemKindURLs.append(url.standardizedFileURL)
        guard let result = itemKinds[url.standardizedFileURL.path] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return try result.get()
    }

    func readData(at url: URL) throws -> Data {
        let standardizedURL = url.standardizedFileURL
        readDataURLs.append(standardizedURL)
        guard let data = storedData[standardizedURL.path] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        return data
    }

    func createDirectory(at url: URL) throws {}

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        setData(data, at: url)
    }

    func canonicalURL(for url: URL) throws -> URL {
        let key = url.standardizedFileURL.path
        if var results = canonicalURLResults[key], !results.isEmpty {
            let result = results.removeFirst()
            canonicalURLResults[key] = results
            return try result.get()
        }
        return url.standardizedFileURL
    }
}

private final class InMemoryLegacyMigrationStateStore: LegacyMigrationStateStore, @unchecked Sendable {
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
