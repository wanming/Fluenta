import XCTest
@testable import InkletCore

final class OpenAISpeechTranscriptionProviderTests: XCTestCase {
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
            endpoint: URL(string: "https://api.openai.test/v1/audio/transcriptions")!,
            apiKey: "speech-key",
            boundary: "InkletBoundary"
        )
        let body = String(data: try XCTUnwrap(urlRequest.httpBody), encoding: .utf8)

        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.timeoutInterval, 12)
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
            endpoint: URL(string: "https://api.openai.test/v1/audio/transcriptions")!,
            apiKey: "test-key",
            boundary: "InkletBoundary"
        )) { error in
            XCTAssertEqual(error as? SpeechTranscriptionError, .emptyAudio)
        }
    }

    func testUsesSuppliedEndpointModelAndM4AContentType() throws {
        let audioURL = temporaryAudioFile(contents: Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let endpoint = URL(string: "https://speech.example.test/custom")!

        let request = try OpenAISpeechTranscriptionProvider.makeURLRequest(
            SpeechTranscriptionRequest(
                audioFileURL: audioURL,
                model: "frozen-dictation-model",
                timeoutSeconds: 9
            ),
            endpoint: endpoint,
            apiKey: "test-key",
            boundary: "InkletBoundary"
        )
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.timeoutInterval, 9)
        XCTAssertTrue(body.contains("frozen-dictation-model"))
        XCTAssertTrue(body.contains("Content-Type: audio/m4a"))
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
            session: URLSession(configuration: configuration)
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

    private func temporaryAudioFile(contents: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        FileManager.default.createFile(atPath: url.path, contents: contents)
        return url
    }
}

private final class MockSpeechURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
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
