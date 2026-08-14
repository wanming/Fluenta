import Foundation

public struct InkletStoragePaths: Equatable, Sendable {
    public static let productionBundleIdentifier = "com.tomwan.inklet"
    public static let localBundleIdentifier = "com.tomwan.inklet.local"

    public let bundleIdentifier: String
    public let applicationSupportRootURL: URL
    public let historyFileURL: URL
    public let translationCacheFileURL: URL
    public let migrationLockFileURL: URL
    public let selectionDiagnosticsFileURL: URL

    public init(
        bundleIdentifier: String,
        applicationSupportDirectory: URL,
        temporaryDirectory: URL
    ) {
        self.init(
            bundleIdentifier: bundleIdentifier,
            applicationSupportRootURL: applicationSupportDirectory.appendingPathComponent(
                bundleIdentifier,
                isDirectory: true
            ),
            temporaryDirectory: temporaryDirectory
        )
    }

    public init(
        bundleIdentifier: String,
        applicationSupportRootURL: URL,
        temporaryDirectory: URL
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationSupportRootURL = applicationSupportRootURL
        self.historyFileURL = applicationSupportRootURL.appendingPathComponent("history.jsonl")
        self.translationCacheFileURL = applicationSupportRootURL.appendingPathComponent(
            "selection-translation-cache.json"
        )
        self.migrationLockFileURL = applicationSupportRootURL.appendingPathComponent(
            "legacy-migration.lock"
        )
        self.selectionDiagnosticsFileURL = temporaryDirectory.appendingPathComponent(
            "InkletSelectionActions.\(bundleIdentifier).log"
        )
    }

    public static func current(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> InkletStoragePaths {
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            throw InkletStoragePathsError.missingBundleIdentifier
        }

        return InkletStoragePaths(
            bundleIdentifier: bundleIdentifier,
            applicationSupportDirectory: applicationSupportDirectory(fileManager: fileManager),
            temporaryDirectory: fileManager.temporaryDirectory
        )
    }

    package static func currentOrLocalDevelopment(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> InkletStoragePaths {
        do {
            return try current(bundle: bundle, fileManager: fileManager)
        } catch InkletStoragePathsError.missingBundleIdentifier {
            return InkletStoragePaths(
                bundleIdentifier: localBundleIdentifier,
                applicationSupportDirectory: applicationSupportDirectory(fileManager: fileManager),
                temporaryDirectory: fileManager.temporaryDirectory
            )
        } catch {
            preconditionFailure("Unable to resolve Inklet storage paths: \(error)")
        }
    }

    private static func applicationSupportDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
    }
}

public enum InkletStoragePathsError: Error, Equatable {
    case missingBundleIdentifier
}
