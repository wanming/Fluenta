import Foundation

public struct OpenAIProvider: LLMProvider {
    public struct RequestBody: Codable, Equatable {
        public struct InputMessage: Codable, Equatable {
            public var role: String
            public var content: String

            public init(role: String, content: String) {
                self.role = role
                self.content = content
            }
        }

        public var model: String
        public var input: [InputMessage]

        public init(model: String, input: [InputMessage]) {
            self.model = model
            self.input = input
        }
    }

    private struct ResponseBody: Decodable {
        struct OutputItem: Decodable {
            var content: [ContentItem]?
        }

        struct ContentItem: Decodable {
            var type: String?
            var text: String?
        }

        var output: [OutputItem]

        var outputText: String {
            output
                .flatMap { $0.content ?? [] }
                .filter { $0.type == "output_text" }
                .compactMap(\.text)
                .joined()
        }
    }

    private struct ErrorResponseBody: Decodable {
        struct ErrorBody: Decodable {
            var message: String
        }

        var error: ErrorBody
    }

    private let apiKeyProvider: @Sendable () throws -> String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKeyProvider: @escaping @Sendable () throws -> String,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        session: URLSession = .shared
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.endpoint = endpoint
        self.session = session
    }

    public func transform(_ request: TransformationRequest) async throws -> TransformationResult {
        let apiKey = try apiKeyProvider()
        let requestBody = Self.makeRequestBody(for: request)
        let bodyData = try JSONEncoder().encode(requestBody)

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: request.timeoutSeconds)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        let started = Date()
        let (data, response) = try await session.data(for: urlRequest)
        let elapsedMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransformationError.provider("OpenAI 请求失败：HTTP unknown")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TransformationError.provider(Self.providerErrorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let outputText = try Self.parseOutputText(from: data)
        return TransformationResult(
            outputText: outputText,
            providerMetadata: [
                "provider": "openai",
                "model": request.model
            ],
            elapsedMilliseconds: elapsedMilliseconds
        )
    }

    public static func makeRequestBody(for request: TransformationRequest) -> RequestBody {
        RequestBody(
            model: request.model,
            input: [
                RequestBody.InputMessage(role: "system", content: request.systemPrompt),
                RequestBody.InputMessage(role: "user", content: request.sourceText)
            ]
        )
    }

    public static func parseOutputText(from data: Data) throws -> String {
        let outputText = try JSONDecoder().decode(ResponseBody.self, from: data).outputText
        guard !outputText.isEmpty else {
            throw TransformationError.emptyResponse
        }
        return outputText
    }

    static func providerErrorMessage(from data: Data, statusCode: Int) -> String {
        if let errorBody = try? JSONDecoder().decode(ErrorResponseBody.self, from: data) {
            return "OpenAI 请求失败：\(errorBody.error.message)"
        }

        return "OpenAI 请求失败：HTTP \(statusCode)"
    }
}
