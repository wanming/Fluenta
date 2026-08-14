import XCTest
@testable import InkletCore

final class SelectionTranslationServiceTests: XCTestCase {
    func testBuildsTranslationPromptMode() {
        let mode = SelectionTranslationService.promptMode(systemPrompt: "Custom selection prompt.")

        XCTAssertEqual(mode.id, "selection-action-translate")
        XCTAssertFalse(mode.isVisible)
        XCTAssertEqual(mode.systemPrompt, "Custom selection prompt.")
    }

    func testTranslatesWithInjectedService() async throws {
        let service = SelectionTranslationService(
            transform: { source, systemPrompt, model, timeoutSeconds in
                XCTAssertEqual(source, "hello")
                XCTAssertEqual(systemPrompt, "Translate into Japanese.")
                XCTAssertEqual(model, "test-model")
                XCTAssertEqual(timeoutSeconds, 3)
                return "こんにちは"
            }
        )

        let result = try await service.translate(
            sourceText: "hello",
            systemPrompt: "Translate into Japanese.",
            model: "test-model",
            timeoutSeconds: 3
        )

        XCTAssertEqual(result, "こんにちは")
    }

    func testCachedTranslationReturnsWithoutCallingInjectedService() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionTranslationServiceTests-\(UUID().uuidString)")
            .appendingPathComponent("cache.json")
        let cache = JSONSelectionTranslationCache(fileURL: cacheURL)
        let key = SelectionTranslationCacheKey(
            sourceText: "hello",
            targetLanguageName: "Japanese",
            systemPrompt: "Translate into Japanese.",
            model: "test-model",
            providerID: "openai"
        )
        try cache.storeTranslation("こんにちは", for: key, now: Date(timeIntervalSince1970: 100))
        let service = CachedSelectionTranslationService(
            service: SelectionTranslationService { _, _, _, _ in
                XCTFail("Provider should not be called for cached translations.")
                return "network"
            },
            cache: cache
        )

        let result = try await service.translate(
            sourceText: "hello",
            targetLanguageName: "Japanese",
            systemPrompt: "Translate into Japanese.",
            model: "test-model",
            providerID: "openai",
            timeoutSeconds: 3,
            now: Date(timeIntervalSince1970: 101)
        )

        XCTAssertEqual(result, "こんにちは")
    }

    func testCacheMissStoresInjectedServiceTranslation() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionTranslationServiceTests-\(UUID().uuidString)")
            .appendingPathComponent("cache.json")
        let cache = JSONSelectionTranslationCache(fileURL: cacheURL)
        let service = CachedSelectionTranslationService(
            service: SelectionTranslationService { _, _, _, _ in
                "こんにちは"
            },
            cache: cache
        )

        let result = try await service.translate(
            sourceText: "hello",
            targetLanguageName: "Japanese",
            systemPrompt: "Translate into Japanese.",
            model: "test-model",
            providerID: "openai",
            timeoutSeconds: 3,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(result, "こんにちは")

        let cachedOnlyService = CachedSelectionTranslationService(
            service: SelectionTranslationService { _, _, _, _ in
                XCTFail("Provider should not be called after the translation is cached.")
                return "network"
            },
            cache: cache
        )
        let cachedResult = try await cachedOnlyService.translate(
            sourceText: "hello",
            targetLanguageName: "Japanese",
            systemPrompt: "Translate into Japanese.",
            model: "test-model",
            providerID: "openai",
            timeoutSeconds: 3,
            now: Date(timeIntervalSince1970: 101)
        )

        XCTAssertEqual(cachedResult, "こんにちは")
    }
}
