import Foundation

public enum LLMProviderKind: String, Codable, Sendable {
    case openAIResponses
    case openAICompatibleChat
    case anthropicMessages
    case geminiGenerateContent
}

public struct LLMProviderPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var defaultModel: String
    public var apiKeyPlaceholder: String
    public var keychainService: String
    public var kind: LLMProviderKind
    public var endpoint: URL

    public init(
        id: String,
        name: String,
        defaultModel: String,
        apiKeyPlaceholder: String,
        keychainService: String,
        kind: LLMProviderKind,
        endpoint: URL
    ) {
        self.id = id
        self.name = name
        self.defaultModel = defaultModel
        self.apiKeyPlaceholder = apiKeyPlaceholder
        self.keychainService = keychainService
        self.kind = kind
        self.endpoint = endpoint
    }

    public static let openAI = LLMProviderPreset(
        id: "openai",
        name: "OpenAI",
        defaultModel: "gpt-5.6-luna",
        apiKeyPlaceholder: "sk-...",
        keychainService: KeychainStore.defaultService,
        kind: .openAIResponses,
        endpoint: URL(string: "https://api.openai.com/v1/responses")!
    )

    public static let customOpenAICompatible = openAICompatible(
        id: "custom-openai-compatible",
        name: "Custom OpenAI Compatible",
        defaultModel: "gpt-5-mini",
        placeholder: "sk-...",
        service: "Inklet.CustomOpenAICompatible",
        endpoint: "https://api.example.com/v1/chat/completions"
    )

    public static let all: [LLMProviderPreset] = [
        .openAI,
        LLMProviderPreset(
            id: "anthropic",
            name: "Anthropic",
            defaultModel: "claude-haiku-4-5",
            apiKeyPlaceholder: "sk-ant-...",
            keychainService: "Inklet.Anthropic",
            kind: .anthropicMessages,
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!
        ),
        LLMProviderPreset(
            id: "gemini",
            name: "Google Gemini",
            defaultModel: "gemini-flash-latest",
            apiKeyPlaceholder: "AIza...",
            keychainService: "Inklet.Gemini",
            kind: .geminiGenerateContent,
            endpoint: URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        ),
        openAICompatible(
            id: "deepseek",
            name: "DeepSeek",
            defaultModel: "deepseek-v4-flash",
            placeholder: "sk-...",
            service: "Inklet.DeepSeek",
            endpoint: "https://api.deepseek.com/chat/completions"
        ),
        openAICompatible(
            id: "qwen",
            name: "Alibaba Qwen",
            defaultModel: "qwen3.6-plus",
            placeholder: "sk-...",
            service: "Inklet.Qwen",
            endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        ),
        openAICompatible(
            id: "moonshot",
            name: "Moonshot Kimi",
            defaultModel: "kimi-k2.6",
            placeholder: "sk-...",
            service: "Inklet.Moonshot",
            endpoint: "https://api.moonshot.cn/v1/chat/completions"
        ),
        openAICompatible(
            id: "zhipu",
            name: "Zhipu GLM",
            defaultModel: "glm-4.7-flash",
            placeholder: "...",
            service: "Inklet.Zhipu",
            endpoint: "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        ),
        openAICompatible(
            id: "minimax",
            name: "MiniMax",
            defaultModel: "MiniMax-M2.7-highspeed",
            placeholder: "...",
            service: "Inklet.MiniMax",
            endpoint: "https://api.minimax.io/v1/chat/completions"
        ),
        openAICompatible(
            id: "siliconflow",
            name: "SiliconFlow",
            defaultModel: "deepseek-ai/deepseek-v4-flash",
            placeholder: "sk-...",
            service: "Inklet.SiliconFlow",
            endpoint: "https://api.siliconflow.com/v1/chat/completions"
        ),
        openAICompatible(
            id: "volcengine",
            name: "Volcengine Ark",
            defaultModel: "doubao-seed-1-6-flash",
            placeholder: "...",
            service: "Inklet.Volcengine",
            endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        ),
        openAICompatible(
            id: "tencent-hunyuan",
            name: "Tencent Hunyuan",
            defaultModel: "hunyuan-turbos-latest",
            placeholder: "...",
            service: "Inklet.TencentHunyuan",
            endpoint: "https://api.hunyuan.cloud.tencent.com/v1/chat/completions"
        ),
        openAICompatible(
            id: "baichuan",
            name: "Baichuan",
            defaultModel: "Baichuan4-Turbo",
            placeholder: "sk-...",
            service: "Inklet.Baichuan",
            endpoint: "https://api.baichuan-ai.com/v1/chat/completions"
        ),
        openAICompatible(
            id: "lingyiwanwu",
            name: "01.AI Yi",
            defaultModel: "yi-lightning",
            placeholder: "...",
            service: "Inklet.Lingyiwanwu",
            endpoint: "https://api.lingyiwanwu.com/v1/chat/completions"
        ),
        openAICompatible(
            id: "xai",
            name: "xAI",
            defaultModel: "grok-4-fast",
            placeholder: "xai-...",
            service: "Inklet.xAI",
            endpoint: "https://api.x.ai/v1/chat/completions"
        ),
        openAICompatible(
            id: "groq",
            name: "Groq",
            defaultModel: "meta-llama/llama-4-scout-17b-16e-instruct",
            placeholder: "gsk_...",
            service: "Inklet.Groq",
            endpoint: "https://api.groq.com/openai/v1/chat/completions"
        ),
        openAICompatible(
            id: "mistral",
            name: "Mistral",
            defaultModel: "mistral-small-latest",
            placeholder: "...",
            service: "Inklet.Mistral",
            endpoint: "https://api.mistral.ai/v1/chat/completions"
        ),
        openAICompatible(
            id: "openrouter",
            name: "OpenRouter",
            defaultModel: "openai/gpt-5.4-mini",
            placeholder: "sk-or-...",
            service: "Inklet.OpenRouter",
            endpoint: "https://openrouter.ai/api/v1/chat/completions"
        ),
        openAICompatible(
            id: "perplexity",
            name: "Perplexity",
            defaultModel: "sonar",
            placeholder: "pplx-...",
            service: "Inklet.Perplexity",
            endpoint: "https://api.perplexity.ai/chat/completions"
        ),
        openAICompatible(
            id: "together",
            name: "Together AI",
            defaultModel: "Qwen/Qwen3.6-Plus",
            placeholder: "...",
            service: "Inklet.Together",
            endpoint: "https://api.together.xyz/v1/chat/completions"
        ),
        openAICompatible(
            id: "cerebras",
            name: "Cerebras",
            defaultModel: "gpt-oss-120b",
            placeholder: "csk-...",
            service: "Inklet.Cerebras",
            endpoint: "https://api.cerebras.ai/v1/chat/completions"
        ),
        .customOpenAICompatible
    ]

    public static func preset(id: String) -> LLMProviderPreset {
        all.first { $0.id == id } ?? .openAI
    }

    private static func openAICompatible(
        id: String,
        name: String,
        defaultModel: String,
        placeholder: String,
        service: String,
        endpoint: String
    ) -> LLMProviderPreset {
        LLMProviderPreset(
            id: id,
            name: name,
            defaultModel: defaultModel,
            apiKeyPlaceholder: placeholder,
            keychainService: service,
            kind: .openAICompatibleChat,
            endpoint: URL(string: endpoint)!
        )
    }
}
