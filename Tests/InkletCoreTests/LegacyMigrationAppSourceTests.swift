import XCTest

final class LegacyMigrationAppSourceTests: XCTestCase {
    func testMigrationFinishesBeforeAppKitAndDelegateConstruction() throws {
        let source = try appSource(named: "main.swift")

        try assertTokensAppearInOrder(
            [
                "try InkletStoragePaths.current()",
                "LegacySandboxDataMigrator.live(storagePaths: storagePaths)",
                "migrator.migrateAutomatically()",
                "NSApplication.shared",
                "AppDelegate(",
            ],
            in: source
        )

        let beforeMigration = try sourcePrefix(
            endingBefore: "migrator.migrateAutomatically()",
            in: source
        )
        XCTAssertFalse(beforeMigration.contains("NSApplication.shared"))
        XCTAssertFalse(beforeMigration.contains("AppDelegate("))
    }

    func testStartupFailsClosedWithoutAValidSupportedAppBundleIdentifier() throws {
        let source = try appSource(named: "main.swift")
        let pathResolution = try sourceScope(
            startingAt: "let storagePaths",
            endingBefore: "let migrator",
            in: source
        )

        XCTAssertTrue(pathResolution.contains("try InkletStoragePaths.current()"))
        XCTAssertTrue(pathResolution.contains("catch {"))
        XCTAssertTrue(
            pathResolution.contains(
                "preconditionFailure(\"Unable to resolve Inklet storage paths\")"
            )
        )
        XCTAssertFalse(
            pathResolution.contains("catch InkletStoragePathsError.missingBundleIdentifier")
        )
        XCTAssertFalse(pathResolution.contains("currentOrLocalDevelopment"))
        XCTAssertFalse(pathResolution.contains("\\(error)"))
        XCTAssertTrue(pathResolution.contains("switch storagePaths.bundleIdentifier"))
        XCTAssertTrue(pathResolution.contains("InkletStoragePaths.productionBundleIdentifier"))
        XCTAssertTrue(pathResolution.contains("InkletStoragePaths.localBundleIdentifier"))
        XCTAssertTrue(pathResolution.contains("default:"))
        XCTAssertTrue(
            pathResolution.contains(
                "preconditionFailure(\"Unsupported Inklet bundle identifier\")"
            )
        )
    }

    func testAppDelegateUsesExplicitMigrationDependencies() throws {
        let source = try appSource(named: "AppCoordinator.swift")
        let delegate = try sourceScope(
            startingAt: "final class AppDelegate",
            endingBefore: "private enum SelectionPronunciationReturnState",
            in: source
        )

        XCTAssertFalse(delegate.contains("private let coordinator = AppCoordinator()"))
        XCTAssertTrue(delegate.contains("private let coordinator: AppCoordinator"))

        let initializer = try sourceScope(
            startingAt: "init(",
            endingBefore: "func applicationDidFinishLaunching",
            in: delegate
        )
        XCTAssertTrue(initializer.contains("migrationOutcome: LegacySandboxMigrationOutcome"))
        XCTAssertTrue(initializer.contains("migrator: LegacySandboxDataMigrator"))
        XCTAssertTrue(initializer.contains("storagePaths: InkletStoragePaths"))
        XCTAssertTrue(initializer.contains("self.coordinator = AppCoordinator("))
        XCTAssertTrue(initializer.contains("migrationOutcome: migrationOutcome"))
        XCTAssertTrue(initializer.contains("migrator: migrator"))
        XCTAssertTrue(initializer.contains("storagePaths: storagePaths"))
    }

    func testCoordinatorRetainsMigrationStateAndInjectsOneStoragePathGraph() throws {
        let source = try appSource(named: "AppCoordinator.swift")
        let coordinator = try sourceScope(
            startingAt: "final class AppCoordinator",
            endingBefore: nil,
            in: source
        )

        XCTAssertTrue(coordinator.contains("private let migrationOutcome: LegacySandboxMigrationOutcome"))
        XCTAssertTrue(coordinator.contains("private let migrator: LegacySandboxDataMigrator"))
        XCTAssertTrue(coordinator.contains("private let storagePaths: InkletStoragePaths"))

        let initializer = try sourceScope(
            startingAt: "init(",
            endingBefore: "func start()",
            in: coordinator
        )
        XCTAssertTrue(initializer.contains("migrationOutcome: LegacySandboxMigrationOutcome"))
        XCTAssertTrue(initializer.contains("migrator: LegacySandboxDataMigrator"))
        XCTAssertTrue(initializer.contains("storagePaths: InkletStoragePaths"))
        XCTAssertTrue(initializer.contains("self.migrationOutcome = migrationOutcome"))
        XCTAssertTrue(initializer.contains("self.migrator = migrator"))
        XCTAssertTrue(initializer.contains("self.storagePaths = storagePaths"))
        XCTAssertTrue(initializer.contains("JSONLHistoryStore(fileURL: storagePaths.historyFileURL)"))
        XCTAssertTrue(
            initializer.contains("InkletPopoverWindowController(historyStore: historyStore)")
        )
        XCTAssertTrue(
            initializer.contains("SettingsWindowController(historyStore: historyStore)")
        )
        let compactInitializer = initializer.filter { !$0.isWhitespace }
        XCTAssertTrue(
            compactInitializer.contains(
                "JSONSelectionTranslationCache(fileURL:storagePaths.translationCacheFileURL)"
            )
        )
        XCTAssertTrue(
            initializer.contains(
                "SelectionActionDiagnostics.configure(fileURL: storagePaths.selectionDiagnosticsFileURL)"
            )
        )
        XCTAssertFalse(initializer.contains("InkletStoragePaths.current"))
        XCTAssertFalse(coordinator.contains("JSONLHistoryStore()"))
        XCTAssertFalse(coordinator.contains("JSONSelectionTranslationCache()"))
    }

    func testDiagnosticsUseOnlyTheConfiguredStoragePath() throws {
        let source = try appSource(named: "SelectionActionDiagnostics.swift")

        XCTAssertTrue(source.contains("@MainActor"))
        XCTAssertTrue(source.contains("static func configure(fileURL:"))
        XCTAssertTrue(source.contains("guard let url = fileURL else"))
        XCTAssertFalse(source.contains("InkletStoragePaths.current"))
        XCTAssertFalse(source.contains("currentOrLocalDevelopment"))
    }

    private func appSource(named fileName: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/InkletApp", isDirectory: true)
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func sourcePrefix(
        endingBefore endToken: String,
        in source: String
    ) throws -> Substring {
        let end = try XCTUnwrap(source.range(of: endToken))
        return source[source.startIndex..<end.lowerBound]
    }

    private func sourceScope(
        startingAt startToken: String,
        endingBefore endToken: String?,
        in source: some StringProtocol
    ) throws -> Substring {
        let text = String(source)
        let start = try XCTUnwrap(text.range(of: startToken))
        let endIndex: String.Index
        if let endToken {
            let end = try XCTUnwrap(
                text.range(of: endToken, range: start.upperBound..<text.endIndex)
            )
            endIndex = end.lowerBound
        } else {
            endIndex = text.endIndex
        }
        return text[start.lowerBound..<endIndex]
    }

    private func assertTokensAppearInOrder(
        _ tokens: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var searchStart = source.startIndex
        for token in tokens {
            let range = try XCTUnwrap(
                source.range(of: token, range: searchStart..<source.endIndex),
                "Missing startup token: \(token)",
                file: file,
                line: line
            )
            searchStart = range.upperBound
        }
    }
}
