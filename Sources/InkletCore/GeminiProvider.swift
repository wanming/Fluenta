import Foundation

public struct GeminiProvider: LLMProvider {
    public struct RequestBody: Codable, Equatable {
        public struct Part: Codable, Equatable {
            public var text: String
        }

        public struct Content: Codable, Equatable {
            public var role: String?
            public var parts: [Part]
        }

        public var systemInstruction: Content
        public var contents: [Content]
    }

    private struct ResponseBody: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    var text: String?
                }

                var parts: [Part]?
            }

            var content: Content?
        }

        var candidates: [Candidate]
    }

    private struct ErrorResponseBody: Decodable {
        struct ErrorBody: Decodable {
            var message: String?
        }

        var error: ErrorBody
    }

    private let apiKeyProvider: @Sendable () throws -> String
    private let baseURL: URL
    private let session: URLSession

    public init(
        apiKeyProvider: @escaping @Sendable () throws -> String,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        session: URLSession = .shared
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.baseURL = baseURL
        self.session = session
    }

    public func transform(_ request: TransformationRequest) async throws -> TransformationResult {
        let apiKey = try apiKeyProvider()
        let bodyData = try JSONEncoder().encode(Self.makeRequestBody(for: request))
        let encodedModel = request.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? request.model
        let endpoint = baseURL
            .appendingPathComponent("models")
            .appendingPathComponent(encodedModel)
            .appendingPathComponent("generateContent")

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = components?.url else {
            throw TransformationError.provider("Gemini 请求失败：URL 无效")
        }

        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeoutSeconds)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        let started = Date()
        let (data, response) = try await session.data(for: urlRequest)
        let elapsedMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransformationError.provider("Gemini 请求失败：HTTP unknown")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TransformationError.provider(Self.providerErrorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        let outputText = try Self.parseOutputText(from: data)
        return TransformationResult(
            outputText: outputText,
            providerMetadata: [
                "provider": "gemini",
                "model": request.model
            ],
            elapsedMilliseconds: elapsedMilliseconds
        )
    }

    public static func makeRequestBody(for request: TransformationRequest) -> RequestBody {
        RequestBody(
            systemInstruction: .init(role: nil, parts: [.init(text: request.systemPrompt)]),
            contents: [
                .init(role: "user", parts: [.init(text: request.sourceText)])
            ]
        )
    }

    public static func parseOutputText(from data: Data) throws -> String {
        let outputText = try JSONDecoder()
            .decode(ResponseBody.self, from: data)
            .candidates
            .flatMap { $0.content?.parts ?? [] }
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
            return "Gemini 请求失败：\(message)"
        }

        return "Gemini 请求失败：HTTP \(statusCode)"
    }
}
