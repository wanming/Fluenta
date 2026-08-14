import XCTest
@testable import InkletCore

final class SelectionTranslationCacheTests: XCTestCase {
    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionTranslationCacheTests-\(UUID().uuidString)")
            .appendingPathComponent("selection-translation-cache.json")
    }

    private func cacheKey(
        sourceText: String = "hello",
        targetLanguageName: String = "Simplified Chinese",
        systemPrompt: String = "Translate into Simplified Chinese.",
        model: String = "gpt-test",
        providerID: String = "openai",
        temperature: Double = 0.2
    ) -> SelectionTranslationCacheKey {
        SelectionTranslationCacheKey(
            sourceText: sourceText,
            targetLanguageName: targetLanguageName,
            systemPrompt: systemPrompt,
            model: model,
            providerID: providerID,
            temperature: temperature
        )
    }

    func testDefaultFileURLUsesQualifiedStoragePath() {
        let paths = InkletStoragePaths(
            bundleIdentifier: "com.tomwan.inklet.local",
            applicationSupportDirectory: URL(fileURLWithPath: "/Users/test/Library/Application Support"),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/test")
        )

        XCTAssertEqual(
            JSONSelectionTranslationCache.defaultFileURL(storagePaths: paths),
            paths.translationCacheFileURL
        )
    }

    func testStoredTranslationIsReturnedWithinSevenDays() throws {
        let url = temporaryCacheURL()
        let cache = JSONSelectionTranslationCache(fileURL: url)
        let createdAt = Date(timeIntervalSince1970: 100)

        try cache.storeTranslation("你好", for: cacheKey(), now: createdAt)

        XCTAssertEqual(
            try cache.translation(for: cacheKey(), now: createdAt.addingTimeInterval((7 * 24 * 60 * 60) - 1)),
            "你好"
        )
    }

    func testStoredTranslationExpiresAtSevenDays() throws {
        let url = temporaryCacheURL()
        let cache = JSONSelectionTranslationCache(fileURL: url)
        let createdAt = Date(timeIntervalSince1970: 100)

        try cache.storeTranslation("你好", for: cacheKey(), now: createdAt)

        XCTAssertNil(
            try cache.translation(for: cacheKey(), now: createdAt.addingTimeInterval(7 * 24 * 60 * 60))
        )
    }

    func testCacheKeyIncludesTranslationSettings() throws {
        let url = temporaryCacheURL()
        let cache = JSONSelectionTranslationCache(fileURL: url)
        let createdAt = Date(timeIntervalSince1970: 100)

        try cache.storeTranslation("你好", for: cacheKey(), now: createdAt)

        XCTAssertNil(try cache.translation(for: cacheKey(systemPrompt: "Translate casually."), now: createdAt))
        XCTAssertNil(try cache.translation(for: cacheKey(model: "other-model"), now: createdAt))
        XCTAssertNil(try cache.translation(for: cacheKey(providerID: "other-provider"), now: createdAt))
        XCTAssertNil(try cache.translation(for: cacheKey(temperature: 0.8), now: createdAt))
    }

    func testCacheFileDoesNotStoreSourceTextInPlaintext() throws {
        let url = temporaryCacheURL()
        let cache = JSONSelectionTranslationCache(fileURL: url)

        try cache.storeTranslation("你好", for: cacheKey(sourceText: "private source text"), now: Date(timeIntervalSince1970: 100))

        let storedText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(storedText.contains("private source text"))
        XCTAssertTrue(storedText.contains("你好"))
    }
}
