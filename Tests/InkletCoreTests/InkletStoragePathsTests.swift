import XCTest
@testable import InkletCore

final class InkletStoragePathsTests: XCTestCase {
    func testProductionPathsAreQualifiedByBundleIdentifier() {
        XCTAssertEqual(InkletStoragePaths.productionBundleIdentifier, "com.tomwan.inklet")

        let production = InkletStoragePaths(
            bundleIdentifier: "com.tomwan.inklet",
            applicationSupportDirectory: URL(fileURLWithPath: "/Users/test/Library/Application Support"),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/test")
        )

        XCTAssertEqual(
            production.applicationSupportRootURL.path,
            "/Users/test/Library/Application Support/com.tomwan.inklet"
        )
        XCTAssertEqual(production.historyFileURL.lastPathComponent, "history.jsonl")
        XCTAssertEqual(
            production.translationCacheFileURL.lastPathComponent,
            "selection-translation-cache.json"
        )
        XCTAssertEqual(production.migrationLockFileURL.lastPathComponent, "legacy-migration.lock")
        XCTAssertEqual(
            production.selectionDiagnosticsFileURL.lastPathComponent,
            "InkletSelectionActions.com.tomwan.inklet.log"
        )
    }

    func testLocalPathsAreQualifiedByBundleIdentifierAndDifferFromProduction() {
        XCTAssertEqual(InkletStoragePaths.localBundleIdentifier, "com.tomwan.inklet.local")

        let applicationSupportDirectory = URL(
            fileURLWithPath: "/Users/test/Library/Application Support"
        )
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/test")
        let production = InkletStoragePaths(
            bundleIdentifier: "com.tomwan.inklet",
            applicationSupportDirectory: applicationSupportDirectory,
            temporaryDirectory: temporaryDirectory
        )
        let local = InkletStoragePaths(
            bundleIdentifier: "com.tomwan.inklet.local",
            applicationSupportDirectory: applicationSupportDirectory,
            temporaryDirectory: temporaryDirectory
        )

        XCTAssertEqual(
            local.applicationSupportRootURL.path,
            "/Users/test/Library/Application Support/com.tomwan.inklet.local"
        )
        XCTAssertEqual(local.historyFileURL.lastPathComponent, "history.jsonl")
        XCTAssertEqual(
            local.translationCacheFileURL.lastPathComponent,
            "selection-translation-cache.json"
        )
        XCTAssertEqual(local.migrationLockFileURL.lastPathComponent, "legacy-migration.lock")
        XCTAssertEqual(
            local.selectionDiagnosticsFileURL.lastPathComponent,
            "InkletSelectionActions.com.tomwan.inklet.local.log"
        )
        XCTAssertNotEqual(production.applicationSupportRootURL, local.applicationSupportRootURL)
        XCTAssertNotEqual(production.historyFileURL, local.historyFileURL)
        XCTAssertNotEqual(production.translationCacheFileURL, local.translationCacheFileURL)
        XCTAssertNotEqual(production.migrationLockFileURL, local.migrationLockFileURL)
        XCTAssertNotEqual(production.selectionDiagnosticsFileURL, local.selectionDiagnosticsFileURL)
    }

    func testQualifiedApplicationSupportRootIsUsedDirectly() {
        let applicationSupportRootURL = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/com.tomwan.inklet"
        )

        let paths = InkletStoragePaths(
            bundleIdentifier: "com.tomwan.inklet",
            applicationSupportRootURL: applicationSupportRootURL,
            temporaryDirectory: URL(fileURLWithPath: "/tmp/test")
        )

        XCTAssertEqual(paths.applicationSupportRootURL, applicationSupportRootURL)
        XCTAssertEqual(
            paths.historyFileURL.path,
            "/Users/test/Library/Application Support/com.tomwan.inklet/history.jsonl"
        )
        XCTAssertEqual(
            paths.translationCacheFileURL.path,
            "/Users/test/Library/Application Support/com.tomwan.inklet/selection-translation-cache.json"
        )
        XCTAssertEqual(
            paths.migrationLockFileURL.path,
            "/Users/test/Library/Application Support/com.tomwan.inklet/legacy-migration.lock"
        )
        XCTAssertEqual(
            paths.selectionDiagnosticsFileURL.path,
            "/tmp/test/InkletSelectionActions.com.tomwan.inklet.log"
        )
    }

    func testCurrentThrowsWhenBundleIdentifierIsMissing() throws {
        let bundle = try makeBundle()

        XCTAssertThrowsError(try InkletStoragePaths.current(bundle: bundle)) { error in
            XCTAssertEqual(error as? InkletStoragePathsError, .missingBundleIdentifier)
        }
    }

    func testCurrentOrLocalDevelopmentUsesQualifiedLocalPathsWhenBundleIdentifierIsMissing() throws {
        let fileManager = FileManager.default
        let bundle = try makeBundle()

        let paths = InkletStoragePaths.currentOrLocalDevelopment(
            bundle: bundle,
            fileManager: fileManager
        )

        XCTAssertEqual(paths.bundleIdentifier, InkletStoragePaths.localBundleIdentifier)
        XCTAssertEqual(
            paths.applicationSupportRootURL,
            applicationSupportDirectory(fileManager: fileManager).appendingPathComponent(
                InkletStoragePaths.localBundleIdentifier,
                isDirectory: true
            )
        )
        XCTAssertEqual(paths.historyFileURL.deletingLastPathComponent(), paths.applicationSupportRootURL)
        XCTAssertEqual(
            paths.translationCacheFileURL.deletingLastPathComponent(),
            paths.applicationSupportRootURL
        )
        XCTAssertEqual(
            paths.migrationLockFileURL.deletingLastPathComponent(),
            paths.applicationSupportRootURL
        )
        XCTAssertEqual(
            paths.selectionDiagnosticsFileURL,
            fileManager.temporaryDirectory.appendingPathComponent(
                "InkletSelectionActions.com.tomwan.inklet.local.log"
            )
        )
    }

    func testCurrentOrLocalDevelopmentPreservesIdentifiedBundlePaths() throws {
        for bundleIdentifier in [
            InkletStoragePaths.productionBundleIdentifier,
            InkletStoragePaths.localBundleIdentifier,
        ] {
            let bundle = try makeBundle(bundleIdentifier: bundleIdentifier)

            let paths = InkletStoragePaths.currentOrLocalDevelopment(bundle: bundle)

            XCTAssertEqual(paths.bundleIdentifier, bundleIdentifier)
            XCTAssertEqual(paths.applicationSupportRootURL.lastPathComponent, bundleIdentifier)
            XCTAssertEqual(
                paths.selectionDiagnosticsFileURL.lastPathComponent,
                "InkletSelectionActions.\(bundleIdentifier).log"
            )
        }
    }

    private func makeBundle(bundleIdentifier: String? = nil) throws -> Bundle {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InkletStoragePathsTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("bundle")
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: bundleURL)
        }

        if let bundleIdentifier {
            let infoPlistData = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": bundleIdentifier,
                    "CFBundlePackageType": "BNDL",
                ],
                format: .xml,
                options: 0
            )
            try infoPlistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        }

        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    private func applicationSupportDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
    }
}
