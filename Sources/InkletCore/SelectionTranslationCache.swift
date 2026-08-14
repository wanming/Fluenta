import CryptoKit
import Foundation

public struct SelectionTranslationCacheKey: Codable, Equatable, Sendable {
    public var sourceText: String
    public var targetLanguageName: String
    public var systemPrompt: String
    public var model: String
    public var providerID: String
    public var temperature: Double

    public init(
        sourceText: String,
        targetLanguageName: String,
        systemPrompt: String,
        model: String,
        providerID: String,
        temperature: Double
    ) {
        self.sourceText = sourceText
        self.targetLanguageName = targetLanguageName
        self.systemPrompt = systemPrompt
        self.model = model
        self.providerID = providerID
        self.temperature = temperature
    }
}

public final class JSONSelectionTranslationCache: @unchecked Sendable {
    public static let defaultTimeToLive: TimeInterval = 7 * 24 * 60 * 60

    private struct Entry: Codable, Equatable {
        var translatedText: String
        var createdAt: Date
    }

    private let fileURL: URL
    private let timeToLive: TimeInterval
    private let lock = NSLock()

    public convenience init(
        timeToLive: TimeInterval = JSONSelectionTranslationCache.defaultTimeToLive
    ) {
        let storagePaths = InkletStoragePaths.currentOrLocalDevelopment()
        self.init(
            fileURL: Self.defaultFileURL(storagePaths: storagePaths),
            timeToLive: timeToLive
        )
    }

    public init(
        fileURL: URL,
        timeToLive: TimeInterval = JSONSelectionTranslationCache.defaultTimeToLive
    ) {
        self.fileURL = fileURL
        self.timeToLive = timeToLive
    }

    public func translation(
        for key: SelectionTranslationCacheKey,
        now: Date = Date()
    ) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        let hash = try Self.cacheKeyHash(for: key)
        var entries = try loadEntries()
        purgeExpiredEntries(from: &entries, now: now)

        guard let entry = entries[hash] else {
            try writeEntries(entries)
            return nil
        }

        try writeEntries(entries)
        return entry.translatedText
    }

    public func storeTranslation(
        _ translatedText: String,
        for key: SelectionTranslationCacheKey,
        now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let hash = try Self.cacheKeyHash(for: key)
        var entries = try loadEntries()
        purgeExpiredEntries(from: &entries, now: now)
        entries[hash] = Entry(translatedText: translatedText, createdAt: now)
        try writeEntries(entries)
    }

    public static func defaultFileURL(storagePaths: InkletStoragePaths) -> URL {
        storagePaths.translationCacheFileURL
    }

    private func loadEntries() throws -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: fileURL)
        return try Self.makeDecoder().decode([String: Entry].self, from: data)
    }

    private func writeEntries(_ entries: [String: Entry]) throws {
        if entries.isEmpty {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return
            }
            try FileManager.default.removeItem(at: fileURL)
            return
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.makeEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    private func purgeExpiredEntries(from entries: inout [String: Entry], now: Date) {
        entries = entries.filter { _, entry in
            entry.createdAt.addingTimeInterval(timeToLive) > now
        }
    }

    private static func cacheKeyHash(for key: SelectionTranslationCacheKey) throws -> String {
        let data = try makeKeyEncoder().encode(key)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeKeyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
