import Foundation
import XCTest
@testable import InkletCore

final class HistoryStoreTests: XCTestCase {
    private func temporaryHistoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)")
            .appendingPathComponent("history.jsonl")
    }

    func testDefaultFileURLUsesQualifiedStoragePath() {
        let paths = InkletStoragePaths(
            bundleIdentifier: "com.tomwan.inklet.local",
            applicationSupportDirectory: URL(fileURLWithPath: "/Users/test/Library/Application Support"),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/test")
        )

        XCTAssertEqual(JSONLHistoryStore.defaultFileURL(storagePaths: paths), paths.historyFileURL)
    }

    func testAppendAndLoadKeepsInsertionOrder() throws {
        let url = temporaryHistoryURL()
        let store = JSONLHistoryStore(fileURL: url)
        let first = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 10),
            source: .write,
            inputText: "rough",
            outputText: "polished",
            modeName: "Polish",
            targetLanguageName: nil,
            model: "gpt-test",
            metadata: ["modeID": "polish"]
        )
        let second = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 20),
            source: .selection,
            inputText: "hello",
            outputText: "ni hao",
            modeName: nil,
            targetLanguageName: "Simplified Chinese",
            model: "gpt-test",
            metadata: [:]
        )

        try store.append(first)
        try store.append(second)

        XCTAssertEqual(try store.load(), [first, second])
    }

    func testAppendSkipsConsecutiveDuplicateRecordsIgnoringIdentityAndTimestamp() throws {
        let url = temporaryHistoryURL()
        let store = JSONLHistoryStore(fileURL: url)
        let first = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            createdAt: Date(timeIntervalSince1970: 10),
            source: .write,
            inputText: "rough",
            outputText: "polished",
            modeName: "Polish",
            model: "gpt-test",
            metadata: ["modeID": "polish", "providerID": "openai"]
        )
        let duplicate = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            createdAt: Date(timeIntervalSince1970: 20),
            source: .write,
            inputText: "rough",
            outputText: "polished",
            modeName: "Polish",
            model: "gpt-test",
            metadata: ["modeID": "polish", "providerID": "openai"]
        )

        try store.append(first)
        try store.append(duplicate)

        XCTAssertEqual(try store.load(), [first])
    }

    func testAppendKeepsNonConsecutiveDuplicateRecords() throws {
        let url = temporaryHistoryURL()
        let store = JSONLHistoryStore(fileURL: url)
        let first = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            createdAt: Date(timeIntervalSince1970: 10),
            source: .selection,
            inputText: "hello",
            outputText: "ni hao",
            targetLanguageName: "Simplified Chinese",
            model: "gpt-test"
        )
        let middle = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            createdAt: Date(timeIntervalSince1970: 20),
            source: .write,
            inputText: "rough",
            outputText: "polished",
            modeName: "Polish",
            model: "gpt-test"
        )
        let laterDuplicate = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
            createdAt: Date(timeIntervalSince1970: 30),
            source: .selection,
            inputText: "hello",
            outputText: "ni hao",
            targetLanguageName: "Simplified Chinese",
            model: "gpt-test"
        )

        try store.append(first)
        try store.append(middle)
        try store.append(laterDuplicate)

        XCTAssertEqual(try store.load(), [first, middle, laterDuplicate])
    }

    func testClearRemovesStoredRecords() throws {
        let url = temporaryHistoryURL()
        let store = JSONLHistoryStore(fileURL: url)
        try store.append(HistoryItem(source: .voice, inputText: "um hi", outputText: "Hi."))

        try store.clear()

        XCTAssertEqual(try store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testConcurrentAppendsKeepAllRecords() async throws {
        let url = temporaryHistoryURL()
        let store = JSONLHistoryStore(fileURL: url)
        let recordCount = 50

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<recordCount {
                group.addTask {
                    try store.append(HistoryItem(
                        source: .write,
                        inputText: "input-\(index)",
                        outputText: "output-\(index)"
                    ))
                }
            }
            try await group.waitForAll()
        }

        let items = try store.load()

        XCTAssertEqual(items.count, recordCount)
        XCTAssertEqual(Set(items.map(\.inputText)).count, recordCount)
        XCTAssertEqual(Set(items.map(\.outputText)).count, recordCount)
    }

    func testLoadSkipsMalformedLines() throws {
        let url = temporaryHistoryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let valid = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            createdAt: Date(timeIntervalSince1970: 30),
            source: .write,
            inputText: "a",
            outputText: "b"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validLine = String(decoding: try encoder.encode(valid), as: UTF8.self)
        try "not-json\n\(validLine)\n".write(to: url, atomically: true, encoding: .utf8)

        let store = JSONLHistoryStore(fileURL: url)

        XCTAssertEqual(try store.load(), [valid])
    }

    func testLegacyVoiceHistoryEntryStillDecodesFromLiteralJSONL() throws {
        let url = temporaryHistoryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let line = #"{"createdAt":"2023-11-14T22:13:20Z","id":"00000000-0000-0000-0000-000000000099","inputText":"legacy transcript","metadata":{"providerID":"openai"},"modeName":"Voice Cleanup","model":"legacy-speech","outputText":"legacy transcript","source":"voice"}"#
        try Data((line + "\n").utf8).write(to: url)

        let loaded = try JSONLHistoryStore(fileURL: url).load()

        XCTAssertEqual(loaded, [HistoryItem(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .voice,
            inputText: "legacy transcript",
            outputText: "legacy transcript",
            modeName: "Voice Cleanup",
            model: "legacy-speech",
            metadata: ["providerID": "openai"]
        )])
    }

    func testHistoryJSONLCodecDecodesISO8601AndSkipsMalformedAndEmptyLines() throws {
        let first = historyItem(idSuffix: 41, timestamp: 10, input: "first")
        let second = historyItem(idSuffix: 42, timestamp: 20, input: "second")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = Data(
            (
                "\n"
                    + String(decoding: try encoder.encode(first), as: UTF8.self)
                    + "\nnot-json\n   \n"
                    + String(decoding: try encoder.encode(second), as: UTF8.self)
                    + "\n"
            ).utf8
        )

        XCTAssertEqual(HistoryJSONLCodec.decodeValidItems(from: data), [first, second])
    }

    func testHistoryJSONLCodecEncodeIsDeterministicAndNewlineDelimited() throws {
        let items = [
            historyItem(idSuffix: 51, timestamp: 10, input: "first"),
            historyItem(idSuffix: 52, timestamp: 20, input: "second"),
        ]

        let firstEncoding = try HistoryJSONLCodec.encode(items)
        let secondEncoding = try HistoryJSONLCodec.encode(items)

        XCTAssertEqual(firstEncoding, secondEncoding)
        XCTAssertEqual(firstEncoding.last, 0x0A)
        let lines = String(decoding: firstEncoding, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.first == "{" && $0.last == "}" })
        XCTAssertEqual(HistoryJSONLCodec.decodeValidItems(from: firstEncoding), items)

        let firstLine = String(lines[0])
        let keyPositions = [
            "\"createdAt\"",
            "\"id\"",
            "\"inputText\"",
            "\"metadata\"",
            "\"outputText\"",
            "\"source\"",
        ].compactMap { firstLine.range(of: $0)?.lowerBound }
        XCTAssertEqual(keyPositions.count, 6)
        XCTAssertEqual(keyPositions, keyPositions.sorted())
    }

    func testHistoryJSONLCodecEncodesEmptyCollectionAsEmptyData() throws {
        XCTAssertEqual(try HistoryJSONLCodec.encode([]), Data())
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
            modeName: "Polish",
            model: "test-model",
            metadata: ["z": "last", "a": "first"]
        )
    }
}
