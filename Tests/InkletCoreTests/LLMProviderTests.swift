import XCTest
@testable import InkletCore

final class LLMProviderTests: XCTestCase {
    func testProviderPresetCoversMainstreamProviders() {
        XCTAssertEqual(
            LLMProviderPreset.all.map(\.id),
            [
                "openai",
                "anthropic",
                "gemini",
                "deepseek",
                "qwen",
                "moonshot",
                "zhipu",
                "minimax",
                "siliconflow",
                "volcengine",
                "tencent-hunyuan",
                "baichuan",
                "lingyiwanwu",
                "xai",
                "groq",
                "mistral",
                "openrouter",
                "perplexity",
                "together",
                "cerebras",
                "custom-openai-compatible"
            ]
        )
    }

    func testProviderDefaultsUseCurrentFastModels() {
        let defaults = Dictionary(uniqueKeysWithValues: LLMProviderPreset.all.map { ($0.id, $0.defaultModel) })

        XCTAssertEqual(defaults["openai"], "gpt-5.6-luna")
        XCTAssertEqual(defaults["anthropic"], "claude-haiku-4-5")
        XCTAssertEqual(defaults["gemini"], "gemini-flash-latest")
        XCTAssertEqual(defaults["deepseek"], "deepseek-v4-flash")
        XCTAssertEqual(defaults["qwen"], "qwen3.6-plus")
        XCTAssertEqual(defaults["minimax"], "MiniMax-M2.7-highspeed")
        XCTAssertEqual(defaults["groq"], "meta-llama/llama-4-scout-17b-16e-instruct")
        XCTAssertEqual(defaults["openrouter"], "openai/gpt-5.4-mini")
        XCTAssertEqual(defaults["custom-openai-compatible"], "gpt-5-mini")
        XCTAssertTrue(LLMProviderPreset.all.allSatisfy { !$0.defaultModel.isEmpty })
    }

    func testChatCompletionBuildsOpenAICompatibleRequestWithoutTemperature() throws {
        let body = ChatCompletionProvider.makeRequestBody(for: request)
        let json = try encodedJSONObject(body)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        XCTAssertNil(json["temperature"])
        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages.compactMap { $0["content"] as? String }, ["Rewrite clearly.", "Hello"])
    }

    func testChatCompletionParsesResponseText() throws {
        let json = #"{"choices":[{"message":{"content":"Hi there."}}]}"#
        let data = try XCTUnwrap(json.data(using: .utf8))

        XCTAssertEqual(try ChatCompletionProvider.parseOutputText(from: data), "Hi there.")
    }

    func testAnthropicBuildsMessagesRequestWithoutTemperature() throws {
        let body = AnthropicProvider.makeRequestBody(for: request)
        let json = try encodedJSONObject(body)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])

        XCTAssertNil(json["temperature"])
        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(json["system"] as? String, "Rewrite clearly.")
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(content.first?["text"] as? String, "Hello")
    }

    func testAnthropicParsesResponseText() throws {
        let json = #"{"content":[{"type":"text","text":"Hi there."}]}"#
        let data = try XCTUnwrap(json.data(using: .utf8))

        XCTAssertEqual(try AnthropicProvider.parseOutputText(from: data), "Hi there.")
    }

    func testGeminiBuildsGenerateContentRequestWithoutGenerationConfig() throws {
        let body = GeminiProvider.makeRequestBody(for: request)
        let json = try encodedJSONObject(body)
        let systemInstruction = try XCTUnwrap(json["systemInstruction"] as? [String: Any])
        let systemParts = try XCTUnwrap(systemInstruction["parts"] as? [[String: Any]])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let userParts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])

        XCTAssertNil(json["generationConfig"])
        XCTAssertEqual(systemParts.first?["text"] as? String, "Rewrite clearly.")
        XCTAssertEqual(contents.first?["role"] as? String, "user")
        XCTAssertEqual(userParts.first?["text"] as? String, "Hello")
    }

    func testGeminiParsesResponseText() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"Hi there."}]}}]}"#
        let data = try XCTUnwrap(json.data(using: .utf8))

        XCTAssertEqual(try GeminiProvider.parseOutputText(from: data), "Hi there.")
    }

    private func encodedJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var request: TransformationRequest {
        TransformationRequest(
            sourceText: "Hello",
            systemPrompt: "Rewrite clearly.",
            modeID: "polish",
            modeName: "Polish",
            model: "test-model",
            timeoutSeconds: 10
        )
    }
}
