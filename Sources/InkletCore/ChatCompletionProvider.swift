import Foundation

public struct ChatCompletionProvider: LLMProvider {
    public struct RequestBody: Codable, Equatable {
        public struct Message: Codable, Equatable {
            public var role: String
            public var content: String
        }

        public var model: String
        public var messages: [Message]
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
            }

            var message: Message?
        }

        var choices: [Choice]
    }

    private struct ErrorResponseBody: Decodable {
        struct ErrorBody: Decodable {
            var message: String?
        }

        var error: ErrorBody
    }

    private let name: String
    private let apiKeyProvider: @Sendable () throws -> String
    private let endpoint: URL
    private let session: URLSession

    public init(
        name: String,
        apiKeyProvider: @escaping @Sendable () throws -> String,
        endpoint: URL,
        session: URLSession = .shared
    ) {
        self.name = name
        self.apiKeyProvider = apiKeyProvider
        self.endpoint = endpoint
        self.session = session
    }

    public func transform(_ request: TransformationRequest) async throws -> TransformationResult {
        let apiKey = try apiKeyProvider()
        let bodyData = try JSONEncoder().encode(Self.makeRequestBody(for: request))

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: request.timeoutSeconds)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        let started = Date()
        let (data, response) = try await session.data(for: urlRequest)
        let elapsedMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransformationError.provider("\(name) 请求失败：HTTP unknown")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TransformationError.provider(providerErrorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let outputText = try Self.parseOutputText(from: data)
        return TransformationResult(
            outputText: outputText,
            providerMetadata: [
                "provider": name,
                "model": request.model
            ],
            elapsedMilliseconds: elapsedMilliseconds
        )
    }

    public static func makeRequestBody(for request: TransformationRequest) -> RequestBody {
        RequestBody(
            model: request.model,
            messages: [
                RequestBody.Message(role: "system", content: request.systemPrompt),
                RequestBody.Message(role: "user", content: request.sourceText)
            ]
        )
    }

    public static func parseOutputText(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(ResponseBody.self, from: data)
        let outputText = response.choices.compactMap(\.message?.content).joined()
        guard !outputText.isEmpty else {
            throw TransformationError.emptyResponse
        }
        return outputText
    }

    private func providerErrorMessage(from data: Data, statusCode: Int) -> String {
        if let errorBody = try? JSONDecoder().decode(ErrorResponseBody.self, from: data),
           let message = errorBody.error.message {
            return "\(name) 请求失败：\(message)"
        }

        return "\(name) 请求失败：HTTP \(statusCode)"
    }
}
