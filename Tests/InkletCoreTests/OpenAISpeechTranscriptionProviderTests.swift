import XCTest
@testable import InkletCore

final class OpenAISpeechTranscriptionProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockSpeechURLProtocol.reset()
    }

    override func tearDown() {
        MockSpeechURLProtocol.reset()
        super.tearDown()
    }

    func testBuildsMultipartTranscriptionRequestWithoutLanguage() throws {
        let audioURL = temporaryAudioFile(contents: Data("fake audio".utf8))
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let request = SpeechTranscriptionRequest(
            audioFileURL: audioURL,
            model: "gpt-4o-mini-transcribe",
            timeoutSeconds: 12
        )

        let urlRequest = try OpenAISpeechTranscriptionProvider.makeURLRequest(
            request,
            apiKey: "speech-key",
            boundary: "InkletBoundary"
        )
        let body = String(data: try XCTUnwrap(urlRequest.httpBody), encoding: .utf8)

        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.timeoutInterval, 12)
        XCTAssertFalse(urlRequest.httpShouldHandleCookies)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer speech-key")
        XCTAssertEqual(
            urlRequest.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=InkletBoundary"
        )
        XCTAssertTrue(body?.contains(#"name="model""#) == true)
        XCTAssertTrue(body?.contains("gpt-4o-mini-transcribe") == true)
        XCTAssertTrue(body?.contains(#"name="file"; filename=""#) == true)
        XCTAssertTrue(body?.contains("fake audio") == true)
        XCTAssertFalse(body?.contains(#"name="language""#) == true)
    }

    func testParsesPlainTextResponse() throws {
        let data = Data("hello there".utf8)

        let result = try OpenAISpeechTranscriptionProvider.parseTranscriptionText(from: data)

        XCTAssertEqual(result, "hello there")
    }

    func testParsesJSONTextResponse() throws {
        let data = try XCTUnwrap(#"{"text":"hello json"}"#.data(using: .utf8))

        let result = try OpenAISpeechTranscriptionProvider.parseTranscriptionText(from: data)

        XCTAssertEqual(result, "hello json")
    }

    func testRejectsZeroByteAudioBeforeBuildingRequest() throws {
        let audioURL = temporaryAudioFile(contents: Data())
        defer { try? FileManager.default.removeItem(at: audioURL) }

        XCTAssertThrowsError(try OpenAISpeechTranscriptionProvider.makeURLRequest(
            SpeechTranscriptionRequest(
                audioFileURL: audioURL,
                model: "gpt-live-transcribe",
                timeoutSeconds: 5
            ),
            apiKey: "test-key",
            boundary: "InkletBoundary"
        )) { error in
            XCTAssertEqual(error as? SpeechTranscriptionError, .emptyAudio)
        }
    }

    func testRequestUsesCanonicalOpenAIRecoveryURLModelAndM4AContentType() throws {
        let audioURL = temporaryAudioFile(contents: Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let request = try OpenAISpeechTranscriptionProvider.makeURLRequest(
            SpeechTranscriptionRequest(
                audioFileURL: audioURL,
                model: "frozen-dictation-model",
                timeoutSeconds: 9
            ),
            apiKey: "test-key",
            boundary: "InkletBoundary"
        )
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        let components = try XCTUnwrap(URLComponents(
            url: XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        ))

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.openai.com/v1/audio/transcriptions"
        )
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.openai.com")
        XCTAssertNil(components.port)
        XCTAssertEqual(components.path, "/v1/audio/transcriptions")
        XCTAssertNil(components.query)
        XCTAssertNil(components.fragment)
        XCTAssertNil(components.user)
        XCTAssertNil(components.password)
        XCTAssertEqual(request.timeoutInterval, 9)
        XCTAssertTrue(body.contains("frozen-dictation-model"))
        XCTAssertTrue(body.contains("Content-Type: audio/m4a"))
    }

    func testProductionSessionConfigurationDisablesPersistentStateAndCaching() {
        let configuration = OpenAISpeechTranscriptionProvider.productionSessionConfiguration()

        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        )
    }

    func testRecoveryRedirectPolicyDeclinesSameAndCrossHostRequests() throws {
        let endpoint = try XCTUnwrap(URL(string: VoiceInputConfig.defaultSpeechEndpoint))
        let delegate = RedirectRejectingDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        for target in [
            "https://api.openai.com/redirected",
            "https://attacker.example/capture"
        ] {
            let task = session.dataTask(with: endpoint)
            let result = RedirectRequestResult()
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: try XCTUnwrap(HTTPURLResponse(
                    url: endpoint,
                    statusCode: 307,
                    httpVersion: nil,
                    headerFields: ["Location": target]
                )),
                newRequest: URLRequest(url: try XCTUnwrap(URL(string: target))),
                completionHandler: { result.record($0) }
            )

            XCTAssertNil(result.request)
            task.cancel()
        }
        XCTAssertTrue(delegate.didRejectRedirect)
    }

    func testWhitespaceResponseIsEmptyResponse() {
        XCTAssertThrowsError(try OpenAISpeechTranscriptionProvider.parseTranscriptionText(from: Data(" \n\t ".utf8))) { error in
            XCTAssertEqual(error as? SpeechTranscriptionError, .emptyResponse)
        }
    }

    func testTranscribePostsAuthorizedRequestAndMapsProviderErrors() async throws {
        MockSpeechURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-speech-key")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)

            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            ))
            let data = try XCTUnwrap("""
            {
              "error": {
                "message": "Invalid API key."
              }
            }
            """.data(using: .utf8))
            return (response, data)
        }
        defer { MockSpeechURLProtocol.handler = nil }

        let audioURL = temporaryAudioFile(contents: Data("fake audio".utf8))
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSpeechURLProtocol.self]
        let provider = OpenAISpeechTranscriptionProvider(
            apiKeyProvider: { "test-speech-key" },
            endpoint: URL(string: "https://api.openai.test/v1/audio/transcriptions")!,
            sessionConfiguration: configuration
        )

        do {
            _ = try await provider.transcribe(SpeechTranscriptionRequest(
                audioFileURL: audioURL,
                model: "gpt-4o-mini-transcribe",
                timeoutSeconds: 5
            ))
            XCTFail("Expected transcription to throw")
        } catch {
            XCTAssertEqual(error as? SpeechTranscriptionError, .provider("OpenAI speech request failed: Invalid API key."))
        }
    }

    func testTranscribeRejectsRedirectBeforeForwardingAuthorizationOrAudio() async throws {
        let endpoint = try XCTUnwrap(URL(string: VoiceInputConfig.defaultSpeechEndpoint))
        let redirectedURL = try XCTUnwrap(URL(string: "https://attacker.example/capture"))
        MockSpeechURLProtocol.redirect = try MockSpeechURLProtocol.Redirect(
            request: URLRequest(url: redirectedURL),
            response: XCTUnwrap(HTTPURLResponse(
                url: endpoint,
                statusCode: 307,
                httpVersion: nil,
                headerFields: ["Location": redirectedURL.absoluteString]
            ))
        )

        let audioURL = temporaryAudioFile(contents: Data("private audio".utf8))
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSpeechURLProtocol.self]
        let provider = OpenAISpeechTranscriptionProvider(
            apiKeyProvider: { "private-speech-key" },
            endpoint: endpoint,
            sessionConfiguration: configuration
        )

        do {
            _ = try await provider.transcribe(SpeechTranscriptionRequest(
                audioFileURL: audioURL,
                model: "gpt-4o-mini-transcribe",
                timeoutSeconds: 5
            ))
            XCTFail("Expected redirect to fail transcription")
        } catch {
            guard case .provider = error as? SpeechTranscriptionError else {
                return XCTFail("Expected provider error, got \(error)")
            }
        }

        let requests = MockSpeechURLProtocol.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, endpoint)
        XCTAssertFalse(requests.contains { request in
            request.url == redirectedURL
                && (request.value(forHTTPHeaderField: "Authorization") != nil || request.httpBody != nil)
        })
    }

    func testRedirectDoesNotMisclassifyLaterTransportFailureOnSameProvider() async throws {
        let endpoint = try XCTUnwrap(URL(string: VoiceInputConfig.defaultSpeechEndpoint))
        let redirectedURL = try XCTUnwrap(URL(string: "https://attacker.example/capture"))
        MockSpeechURLProtocol.redirect = try MockSpeechURLProtocol.Redirect(
            request: URLRequest(url: redirectedURL),
            response: XCTUnwrap(HTTPURLResponse(
                url: endpoint,
                statusCode: 307,
                httpVersion: nil,
                headerFields: ["Location": redirectedURL.absoluteString]
            ))
        )

        let audioURL = temporaryAudioFile(contents: Data("private audio".utf8))
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSpeechURLProtocol.self]
        let provider = OpenAISpeechTranscriptionProvider(
            apiKeyProvider: { "private-speech-key" },
            endpoint: endpoint,
            sessionConfiguration: configuration
        )
        let request = SpeechTranscriptionRequest(
            audioFileURL: audioURL,
            model: "gpt-4o-mini-transcribe",
            timeoutSeconds: 5
        )

        do {
            _ = try await provider.transcribe(request)
            XCTFail("Expected redirect to fail transcription")
        } catch {
            XCTAssertEqual(
                error as? SpeechTranscriptionError,
                .provider("OpenAI speech request failed: HTTP redirect rejected")
            )
        }

        MockSpeechURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await provider.transcribe(request)
            XCTFail("Expected transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("Expected ordinary transport error, got \(error)")
        }

        XCTAssertEqual(MockSpeechURLProtocol.requests.count, 2)
    }

    private func temporaryAudioFile(contents: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        FileManager.default.createFile(atPath: url.path, contents: contents)
        return url
    }
}

private final class RedirectRequestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func record(_ request: URLRequest?) {
        lock.lock()
        storedRequest = request
        lock.unlock()
    }
}

private final class MockSpeechURLProtocol: URLProtocol {
    struct Redirect {
        let request: URLRequest
        let response: HTTPURLResponse
    }

    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var storedRedirect: Redirect?
    nonisolated(unsafe) private static var storedRequests: [URLRequest] = []

    nonisolated(unsafe) static var redirect: Redirect? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedRedirect
        }
        set {
            lock.lock()
            storedRedirect = newValue
            lock.unlock()
        }
    }

    nonisolated(unsafe) static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    static func reset() {
        lock.lock()
        handler = nil
        storedRedirect = nil
        storedRequests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append(request)
        let redirect = Self.storedRedirect
        Self.storedRedirect = nil
        Self.lock.unlock()

        if let redirect {
            client?.urlProtocol(self, wasRedirectedTo: redirect.request, redirectResponse: redirect.response)
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
