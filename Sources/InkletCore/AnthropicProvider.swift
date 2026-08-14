import Foundation

public struct AnthropicProvider: LLMProvider {
    public struct RequestBody: Codable, Equatable {
        public struct Message: Codable, Equatable {
            public struct Content: Codable, Equatable {
                public var type: String
                public var text: String
            }

            public var role: String
            public var content: [Content]
        }

        public var model: String
        public var maxTokens: Int
        public var system: String
        public var messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
        }
    }

    private struct ResponseBody: Decodable {
        struct Content: Decodable {
            var type: String?
            var text: String?
        }

        var content: [Content]
    }

    private struct ErrorResponseBody: Decodable {
        struct ErrorBody: Decodable {
            var message: String?
        }

        var error: ErrorBody
    }

    private let apiKeyProvider: @Sendable () throws -> String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKeyProvider: @escaping @Sendable () throws -> String,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        session: URLSession = .shared
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.endpoint = endpoint
        self.session = session
    }

    public func transform(_ request: TransformationRequest) async throws -> TransformationResult {
        let apiKey = try apiKeyProvider()
        let bodyData = try JSONEncoder().encode(Self.makeRequestBody(for: request))

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: request.timeoutSeconds)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        let started = Date()
        let (data, response) = try await session.data(for: urlRequest)
        let elapsedMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransformationError.provider("Anthropic 请求失败：HTTP unknown")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TransformationError.provider(Self.providerErrorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let outputText = try Self.parseOutputText(from: data)
        return TransformationResult(
            outputText: outputText,
            providerMetadata: [
                "provider": "anthropic",
                "model": request.model
            ],
            elapsedMilliseconds: elapsedMilliseconds
        )
    }

    public static func makeRequestBody(for request: TransformationRequest) -> RequestBody {
        RequestBody(
            model: request.model,
            maxTokens: 4096,
            system: request.systemPrompt,
            messages: [
                RequestBody.Message(
                    role: "user",
                    content: [.init(type: "text", text: request.sourceText)]
                )
            ]
        )
    }

    public static func parseOutputText(from data: Data) throws -> String {
        let outputText = try JSONDecoder()
            .decode(ResponseBody.self, from: data)
            .content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        guard !outputText.isEmpty else {
            throw TransformationError.emptyResponse
        }
        return outputText
    }

    static func providerErrorMessage(from data: Data, statusCode: Int) -> String {
        if let errorBody = try? JSONDecoder().decode(ErrorResponseBody.self, from: data),
           let message = errorBody.error.message {
            return "Anthropic 请求失败：\(message)"
        }

        return "Anthropic 请求失败：HTTP \(statusCode)"
    }
}
