import Darwin
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

struct LegacyMigrationAtomicWriteError: Error, Equatable, Sendable {
    let destinationWasReplaced: Bool
    let posixCode: Int32
}

struct LegacyMigrationDirectorySyncOperations: Sendable {
    let openDirectory: @Sendable (UnsafePointer<CChar>) -> Int32
    let synchronize: @Sendable (Int32) -> Int32
    let close: @Sendable (Int32) -> Int32

    static let live = LegacyMigrationDirectorySyncOperations(
        openDirectory: { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        },
        synchronize: { Darwin.fsync($0) },
        close: { Darwin.close($0) }
    )
}

public struct FileManagerLegacyMigrationFileSystem: LegacyMigrationFileSystem, @unchecked Sendable {
    private let fileManager: FileManager
    private let directorySyncOperations: LegacyMigrationDirectorySyncOperations

    public init(fileManager: FileManager = .default) {
        self.init(
            fileManager: fileManager,
            directorySyncOperations: .live
        )
    }

    init(
        fileManager: FileManager = .default,
        directorySyncOperations: LegacyMigrationDirectorySyncOperations
    ) {
        self.fileManager = fileManager
        self.directorySyncOperations = directorySyncOperations
    }

    public func itemKind(at url: URL) throws -> LegacyMigrationItemKind {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            while true {
                let result = lstat(path, &metadata)
                if result == 0 || errno != EINTR { return result }
            }
        }
        guard result == 0 else { throw Self.posixError() }

        switch metadata.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            return .directory
        case mode_t(S_IFREG):
            return .regularFile
        case mode_t(S_IFLNK):
            return .symbolicLink
        default:
            return .other
        }
    }

    public func readData(at url: URL) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            while true {
                let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                if descriptor >= 0 || errno != EINTR { return descriptor }
            }
        }
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { _ = close(descriptor) }

        var metadata = stat()
        while fstat(descriptor, &metadata) != 0 {
            if errno == EINTR { continue }
            throw Self.posixError()
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw Self.posixError(code: EINVAL)
        }

        var data = Data()
        if metadata.st_size > 0, metadata.st_size <= off_t(Int.max) {
            data.reserveCapacity(Int(metadata.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                while true {
                    let result = Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                    if result >= 0 { return result }
                    if errno != EINTR { return -1 }
                }
            }
            guard count >= 0 else { throw Self.posixError() }
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    public func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    public func writeDataAtomically(_ data: Data, to url: URL) throws {
        let destinationURL = url.standardizedFileURL
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let templateURL = parentURL.appendingPathComponent(
            "\(destinationURL.lastPathComponent).tmp.XXXXXX"
        )
        var template = Array(templateURL.path.utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return mkstemp(baseAddress)
        }
        guard descriptor >= 0 else { throw Self.posixError() }

        let temporaryPath = String(
            decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        var shouldRemoveTemporaryFile = true
        var descriptorIsOpen = true
        var destinationWasReplaced = false
        defer {
            if shouldRemoveTemporaryFile {
                _ = temporaryPath.withCString { unlink($0) }
            }
        }

        do {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw Self.posixError()
            }
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw Self.posixError()
            }
            try Self.writeAll(data, to: descriptor)
            try Self.synchronize(descriptor)
            descriptorIsOpen = false
            guard close(descriptor) == 0 else { throw Self.posixError() }

            let renameResult = temporaryPath.withCString { temporaryPathPointer in
                destinationURL.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                    guard let destinationPath else { return -1 }
                    return rename(temporaryPathPointer, destinationPath)
                }
            }
            guard renameResult == 0 else { throw Self.posixError() }
            shouldRemoveTemporaryFile = false
            destinationWasReplaced = true
            try synchronizeDirectory(parentURL)
        } catch {
            if descriptorIsOpen {
                _ = close(descriptor)
            }
            if destinationWasReplaced {
                let nsError = error as NSError
                let posixCode = nsError.domain == NSPOSIXErrorDomain
                    ? Int32(nsError.code)
                    : EIO
                throw LegacyMigrationAtomicWriteError(
                    destinationWasReplaced: true,
                    posixCode: posixCode
                )
            }
            throw error
        }
    }

    public func canonicalURL(for url: URL) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        _ = try itemKind(at: standardizedURL)
        return standardizedURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard written > 0 else { throw posixError(code: EIO) }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    private func synchronizeDirectory(_ directoryURL: URL) throws {
        let descriptor = directoryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            while true {
                let descriptor = directorySyncOperations.openDirectory(path)
                if descriptor >= 0 || errno != EINTR { return descriptor }
            }
        }
        guard descriptor >= 0 else { throw Self.posixError() }
        var synchronizationErrorCode: Int32?
        while directorySyncOperations.synchronize(descriptor) != 0 {
            let currentErrorCode = errno
            if currentErrorCode == EINTR { continue }
            synchronizationErrorCode = currentErrorCode
            break
        }

        let closeResult = directorySyncOperations.close(descriptor)
        let closeErrorCode = closeResult == 0 ? nil : errno
        if let synchronizationErrorCode {
            throw Self.posixError(code: synchronizationErrorCode)
        }
        if let closeErrorCode {
            throw Self.posixError(code: closeErrorCode)
        }
    }

    private static func posixError(code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
