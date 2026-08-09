import Foundation

public enum LegacyMigrationItemKind: Equatable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case other
}

public protocol LegacyMigrationFileSystem: Sendable {
    func itemKind(at url: URL) throws -> LegacyMigrationItemKind
    func readData(at url: URL) throws -> Data
    func createDirectory(at url: URL) throws
    func writeDataAtomically(_ data: Data, to url: URL) throws
    func canonicalURL(for url: URL) throws -> URL
}

public struct FileManagerLegacyMigrationFileSystem: LegacyMigrationFileSystem, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func itemKind(at url: URL) throws -> LegacyMigrationItemKind {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileType = attributes[.type] as? FileAttributeType else {
            return .other
        }

        switch fileType {
        case .typeDirectory:
            return .directory
        case .typeRegular:
            return .regularFile
        case .typeSymbolicLink:
            return .symbolicLink
        default:
            return .other
        }
    }

    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    public func writeDataAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    public func canonicalURL(for url: URL) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        _ = try itemKind(at: standardizedURL)
        return standardizedURL.resolvingSymlinksInPath().standardizedFileURL
    }
}
