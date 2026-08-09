import Foundation

public enum HistorySource: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case write
    case voice
    case selection

    public var id: String { rawValue }
}

public struct HistoryItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var source: HistorySource
    public var inputText: String
    public var outputText: String
    public var modeName: String?
    public var targetLanguageName: String?
    public var model: String?
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        source: HistorySource,
        inputText: String,
        outputText: String,
        modeName: String? = nil,
        targetLanguageName: String? = nil,
        model: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.inputText = inputText
        self.outputText = outputText
        self.modeName = modeName
        self.targetLanguageName = targetLanguageName
        self.model = model
        self.metadata = metadata
    }

    func hasSameHistoryContent(as other: HistoryItem) -> Bool {
        source == other.source
            && inputText == other.inputText
            && outputText == other.outputText
            && modeName == other.modeName
            && targetLanguageName == other.targetLanguageName
            && model == other.model
            && metadata == other.metadata
    }
}

public protocol HistoryStore: Sendable {
    func load() throws -> [HistoryItem]
    func append(_ item: HistoryItem) throws
    func clear() throws
}

public final class JSONLHistoryStore: HistoryStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public convenience init() {
        let storagePaths = InkletStoragePaths.currentOrLocalDevelopment()
        self.init(fileURL: Self.defaultFileURL(storagePaths: storagePaths))
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [HistoryItem] {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let lines = String(decoding: data, as: UTF8.self).split(
            separator: "\n",
            omittingEmptySubsequences: true
        )
        let decoder = Self.makeDecoder()

        return lines.compactMap { line in
            try? decoder.decode(HistoryItem.self, from: Data(line.utf8))
        }
    }

    public func append(_ item: HistoryItem) throws {
        lock.lock()
        defer { lock.unlock() }

        if try lastStoredItem()?.hasSameHistoryContent(as: item) == true {
            return
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = Self.makeEncoder()
        var data = try encoder.encode(item)
        data.append(0x0A)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: fileURL)
    }

    public static func defaultFileURL(storagePaths: InkletStoragePaths) -> URL {
        storagePaths.historyFileURL
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func lastStoredItem() throws -> HistoryItem? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let lines = String(decoding: data, as: UTF8.self).split(
            separator: "\n",
            omittingEmptySubsequences: true
        )
        let decoder = Self.makeDecoder()

        for line in lines.reversed() {
            if let item = try? decoder.decode(HistoryItem.self, from: Data(line.utf8)) {
                return item
            }
        }

        return nil
    }
}
