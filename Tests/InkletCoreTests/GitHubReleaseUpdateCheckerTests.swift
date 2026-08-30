import Foundation
import XCTest
@testable import InkletCore

final class GitHubReleaseUpdateCheckerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockGitHubReleaseURLProtocol.reset()
    }

    override func tearDown() {
        MockGitHubReleaseURLProtocol.reset()
        super.tearDown()
    }

    func testReleaseVersionParsesMultiDigitCanonicalTag() throws {
        let version = try InkletReleaseVersion(tagName: "v12.34.56-789")

        XCTAssertEqual(version.marketingVersion, "12.34.56")
        XCTAssertEqual(version.buildNumber, 789)
    }

    func testReleaseVersionRejectsNonCanonicalTags() {
        let invalidTags = [
            "1.2.3-4",
            "v01.2.3-4",
            "v1.02.3-4",
            "v1.2.03-4",
            "v+1.2.3-4",
            "v-1.2.3-4",
            "v1.2.3-0",
            "v1.2.3-04",
            "v1.2.3-+4",
            "v1.2.3--4",
            " v1.2.3-4",
            "v1.2.3-4 ",
            "v1.2-4",
            "v1..3-4",
            "v1.2.3.4-5",
            "v1.2.3",
            "v1.2.3-4-beta",
            "v1.2.3-4/extra",
            "v999999999999999999999999999999999999.2.3-4",
            "v1.2.3-999999999999999999999999999999999999"
        ]

        for tag in invalidTags {
            XCTAssertThrowsError(try InkletReleaseVersion(tagName: tag), "Expected \(tag) to be rejected")
        }
    }

    func testReleaseNotesNormalizesTrimsAndHandlesBlankInput() {
        XCTAssertEqual(InkletReleaseNotes.excerpt(nil), "")
        XCTAssertEqual(InkletReleaseNotes.excerpt(" \r\n\t "), "")
        XCTAssertEqual(
            InkletReleaseNotes.excerpt(" \r\nFirst line\rSecond line\r\n "),
            "First line\nSecond line"
        )
        XCTAssertEqual(InkletReleaseNotes.excerpt("text", limit: -1), "")
    }

    func testReleaseNotesKeepsEllipsisWithinLimit() {
        let notes799 = String(repeating: "a", count: 799)
        let notes800 = String(repeating: "a", count: 800)
        let notes801 = String(repeating: "a", count: 801)

        XCTAssertEqual(InkletReleaseNotes.excerpt(notes799).count, 799)
        XCTAssertEqual(InkletReleaseNotes.excerpt(notes800).count, 800)
        XCTAssertEqual(
            InkletReleaseNotes.excerpt(notes801),
            String(repeating: "a", count: 799) + "…"
        )
        XCTAssertEqual(InkletReleaseNotes.excerpt(notes801, limit: 0), "")
        XCTAssertEqual(InkletReleaseNotes.excerpt("ab", limit: 1), "…")
    }

    func testReleaseNotesCountsExtendedGraphemeClusters() {
        let family = "👨‍👩‍👧‍👦"

        XCTAssertEqual(InkletReleaseNotes.excerpt(family + "ab", limit: 2), family + "…")
    }

    func testParserBuildsValidatedRelease() throws {
        let data = try makeReleaseData(
            name: " \nInklet 12.34.56\n ",
            body: " \r\nFirst line\rSecond line\r\n "
        )

        let release = try GitHubReleaseParser.parse(data)

        XCTAssertEqual(release.version, InkletReleaseVersion(marketingVersion: "12.34.56", buildNumber: 789))
        XCTAssertEqual(release.tagName, "v12.34.56-789")
        XCTAssertEqual(release.name, "Inklet 12.34.56")
        XCTAssertEqual(release.notes, "First line\nSecond line")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/wanming/Inklet/releases/tag/v12.34.56-789")
    }

    func testParserAcceptsAnyUploadedExactDMGAsset() throws {
        let release = try GitHubReleaseParser.parse(
            makeReleaseData(
                assets: [
                    ["name": "Inklet.dmg", "state": "uploaded"],
                    ["name": "Inklet.dmg", "state": "pending"],
                    ["name": "other.dmg", "state": "pending"]
                ]
            )
        )

        XCTAssertEqual(release.tagName, "v12.34.56-789")
    }

    func testParserAllowsNullNameAndBody() throws {
        let release = try GitHubReleaseParser.parse(
            makeReleaseData(name: nil, body: nil)
        )

        XCTAssertNil(release.name)
        XCTAssertEqual(release.notes, "")
    }

    func testParserRejectsDraftAndPrereleaseResponses() throws {
        assertValidationError(.unavailableRelease) {
            _ = try GitHubReleaseParser.parse(makeReleaseData(draft: true))
        }
        assertValidationError(.unavailableRelease) {
            _ = try GitHubReleaseParser.parse(makeReleaseData(prerelease: true))
        }
    }

    func testParserRejectsMissingOrNonUploadedDMG() throws {
        assertValidationError(.invalidAsset) {
            _ = try GitHubReleaseParser.parse(makeReleaseData(assets: []))
        }
        assertValidationError(.invalidAsset) {
            _ = try GitHubReleaseParser.parse(
                makeReleaseData(assets: [["name": "Inklet.dmg", "state": "pending"]])
            )
        }
        assertValidationError(.invalidAsset) {
            _ = try GitHubReleaseParser.parse(
                makeReleaseData(assets: [["name": "inklet.dmg", "state": "uploaded"]])
            )
        }
        assertValidationError(.invalidAsset) {
            _ = try GitHubReleaseParser.parse(
                makeReleaseData(assets: [["name": "Inklet.DMG", "state": "uploaded"]])
            )
        }
        XCTAssertThrowsError(
            try GitHubReleaseParser.parse(
                makeReleaseData(assets: [["name": "Inklet.dmg"]])
            )
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testParserRejectsMalformedJSONAndMissingRequiredFields() throws {
        XCTAssertThrowsError(try GitHubReleaseParser.parse(Data("not json".utf8))) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(try GitHubReleaseParser.parse(Data("{}".utf8)))
        assertValidationError(.invalidTag) {
            _ = try GitHubReleaseParser.parse(makeReleaseData(tagName: "v01.2.3-4"))
        }
    }

    func testParserRejectsUntrustedReleasePageURLs() throws {
        let invalidURLs = [
            "http://github.com/wanming/Inklet/releases/tag/v12.34.56-789",
            "https://github.com.evil.example/wanming/Inklet/releases/tag/v12.34.56-789",
            "https://evilgithub.com/wanming/Inklet/releases/tag/v12.34.56-789",
            "https://user:password@github.com/wanming/Inklet/releases/tag/v12.34.56-789",
            "https://github.com:444/wanming/Inklet/releases/tag/v12.34.56-789",
            "https://gith%75b.com/wanming/Inklet/releases/tag/v12.34.56-789",
            "https://github%2Ecom/wanming/Inklet/releases/tag/v12.34.56-789",
            "https://github.com/wanming/Inklet/releases/tag%2Fv12.34.56-789",
            "https://github.com/wanming/Inklet/releases/tag/v12.34.56-789/extra",
            "https://github.com/wanming/Inklet/releases/tag/v12.34.56-789?source=api",
            "https://github.com/wanming/Inklet/releases/tag/v12.34.56-789#notes",
            "https://github.com/wanming/Inklet/releases/tag/v1.2.3-4"
        ]

        for url in invalidURLs {
            assertValidationError(.invalidPageURL, "Expected \(url) to be rejected") {
                _ = try GitHubReleaseParser.parse(makeReleaseData(htmlURL: url))
            }
        }
    }

    func testParserReturnsCanonicalPageURL() throws {
        let release = try GitHubReleaseParser.parse(
            makeReleaseData(htmlURL: "https://GITHUB.com/wanming/Inklet/releases/tag/v12.34.56-789")
        )

        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/wanming/Inklet/releases/tag/v12.34.56-789")
    }

    func testCheckBuildsOneBoundedAnonymousGitHubRequest() async throws {
        MockGitHubReleaseURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/wanming/Inklet/releases/latest")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return try self.httpResponse(for: request, statusCode: 200, data: self.releaseData(buildNumber: 11))
        }

        let result = try await makeChecker().check(currentBuildNumber: "10")

        XCTAssertEqual(result, .updateAvailable(try expectedRelease(buildNumber: 11)))
        XCTAssertEqual(MockGitHubReleaseURLProtocol.requestCount, 1)
    }

    func testCheckComparesRemoteBuildNumberOnly() async throws {
        for (remoteBuild, expectedResult) in [
            (11, AppUpdateCheckResult.updateAvailable(try expectedRelease(buildNumber: 11))),
            (10, AppUpdateCheckResult.upToDate(try expectedRelease(buildNumber: 10))),
            (9, AppUpdateCheckResult.upToDate(try expectedRelease(buildNumber: 9)))
        ] {
            MockGitHubReleaseURLProtocol.reset()
            MockGitHubReleaseURLProtocol.handler = { request in
                try self.httpResponse(for: request, statusCode: 200, data: self.releaseData(buildNumber: remoteBuild))
            }

            let result = try await makeChecker().check(currentBuildNumber: "10")

            XCTAssertEqual(result, expectedResult)
            XCTAssertEqual(MockGitHubReleaseURLProtocol.requestCount, 1)
        }
    }

    func testCheckRejectsMissingOrNonCanonicalCurrentBuildWithoutRequest() async {
        let invalidBuildNumbers: [String?] = [
            nil, "", "0", "01", "+1", "-1", " 1", "1 ", "1.0",
            "999999999999999999999999999999999999"
        ]
        MockGitHubReleaseURLProtocol.handler = { _ in
            XCTFail("The checker must validate the current build before requesting GitHub")
            throw URLError(.badServerResponse)
        }

        for buildNumber in invalidBuildNumbers {
            do {
                _ = try await makeChecker().check(currentBuildNumber: buildNumber)
                XCTFail("Expected \(String(describing: buildNumber)) to be rejected")
            } catch {
                XCTAssertEqual(error as? AppUpdateCheckError, .currentVersionUnavailable)
            }
        }

        XCTAssertEqual(MockGitHubReleaseURLProtocol.requestCount, 0)
    }

    func testCheckMapsNonSuccessHTTPStatusToServiceUnavailable() async {
        for statusCode in [302, 403, 404, 429, 500] {
            MockGitHubReleaseURLProtocol.reset()
            MockGitHubReleaseURLProtocol.handler = { request in
                try self.httpResponse(for: request, statusCode: statusCode, data: Data())
            }

            do {
                _ = try await makeChecker().check(currentBuildNumber: "10")
                XCTFail("Expected status \(statusCode) to fail")
            } catch {
                XCTAssertEqual(error as? AppUpdateCheckError, .serviceUnavailable)
            }
            XCTAssertEqual(MockGitHubReleaseURLProtocol.requestCount, 1)
        }
    }

    func testRedirectDelegateDeclinesRedirectRequest() throws {
        let delegate = RedirectRejectingDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "https://api.github.com/repos/wanming/Inklet/releases/latest")))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(task.currentRequest?.url),
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://github.com/wanming/Inklet/releases/latest"]
        ))
        let expectation = expectation(description: "redirect declined")

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: try XCTUnwrap(URL(string: "https://github.com/wanming/Inklet/releases/latest")))
        ) { redirectRequest in
            XCTAssertNil(redirectRequest)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(delegate.didRejectRedirect)
    }

    func testCheckRejectsNonHTTPResponse() async {
        MockGitHubReleaseURLProtocol.handler = { request in
            let response = URLResponse(
                url: try XCTUnwrap(request.url),
                mimeType: "application/json",
                expectedContentLength: -1,
                textEncodingName: nil
            )
            return (response, try self.releaseData(buildNumber: 11))
        }

        await assertCheckError(.invalidResponse)
    }

    func testCheckRejectsMalformedJSONAndInvalidRelease() async throws {
        let invalidBodies = [
            Data("not json".utf8),
            try makeReleaseData(draft: true)
        ]

        for body in invalidBodies {
            MockGitHubReleaseURLProtocol.reset()
            MockGitHubReleaseURLProtocol.handler = { request in
                try self.httpResponse(for: request, statusCode: 200, data: body)
            }

            await assertCheckError(.invalidResponse)
        }
    }

    func testCheckRejectsOversizedDeclaredAndActualBodies() async throws {
        let oversizedLength = 1_048_577

        MockGitHubReleaseURLProtocol.handler = { request in
            return try self.httpResponse(
                for: request,
                statusCode: 200,
                headers: ["Content-Length": "\(oversizedLength)"],
                data: try self.releaseData(buildNumber: 11)
            )
        }
        await assertCheckError(.invalidResponse)

        MockGitHubReleaseURLProtocol.reset()
        MockGitHubReleaseURLProtocol.handler = { request in
            var data = try self.releaseData(buildNumber: 11)
            data.append(Data(repeating: 32, count: oversizedLength - data.count))
            return try self.httpResponse(
                for: request,
                statusCode: 200,
                data: data
            )
        }
        await assertCheckError(.invalidResponse)
    }

    func testProtocolHarnessResetClearsHandlerAndRequestCount() {
        MockGitHubReleaseURLProtocol.handler = { _ in
            throw URLError(.badServerResponse)
        }
        MockGitHubReleaseURLProtocol.requestCount = 3

        MockGitHubReleaseURLProtocol.reset()

        XCTAssertNil(MockGitHubReleaseURLProtocol.handler)
        XCTAssertEqual(MockGitHubReleaseURLProtocol.requestCount, 0)
    }

    func testCheckAllowsExactlyOneMiBResponseToReachParser() async throws {
        let maximumResponseSize = 1_048_576
        var data = try releaseData(buildNumber: 11)
        data.append(Data(repeating: 32, count: maximumResponseSize - data.count))
        XCTAssertEqual(data.count, maximumResponseSize)

        MockGitHubReleaseURLProtocol.handler = { request in
            try self.httpResponse(for: request, statusCode: 200, data: data)
        }

        let result = try await makeChecker().check(currentBuildNumber: "10")

        XCTAssertEqual(result, .updateAvailable(try expectedRelease(buildNumber: 11)))
    }

    func testCheckMapsOfflineAndTimeoutFailuresToNetworkUnavailable() async {
        for errorCode in [URLError.notConnectedToInternet, URLError.timedOut] {
            MockGitHubReleaseURLProtocol.reset()
            MockGitHubReleaseURLProtocol.handler = { _ in
                throw URLError(errorCode)
            }

            await assertCheckError(.networkUnavailable)
        }
    }

    func testCheckPreservesCancellation() async {
        MockGitHubReleaseURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await makeChecker().check(currentBuildNumber: "10")
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func makeReleaseData(
        tagName: String = "v12.34.56-789",
        name: String? = "Inklet 12.34.56",
        body: String? = "Release notes",
        htmlURL: String? = nil,
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]] = [["name": "Inklet.dmg", "state": "uploaded"]]
    ) throws -> Data {
        var payload: [String: Any] = [
            "tag_name": tagName,
            "html_url": htmlURL ?? "https://github.com/wanming/Inklet/releases/tag/\(tagName)",
            "draft": draft,
            "prerelease": prerelease,
            "assets": assets
        ]
        payload["name"] = name ?? NSNull()
        payload["body"] = body ?? NSNull()
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func makeChecker() -> GitHubReleaseUpdateChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubReleaseURLProtocol.self]
        return GitHubReleaseUpdateChecker(session: URLSession(configuration: configuration))
    }

    private func releaseData(buildNumber: Int) throws -> Data {
        try makeReleaseData(tagName: "v1.2.3-\(buildNumber)")
    }

    private func expectedRelease(buildNumber: Int) throws -> InkletRelease {
        try GitHubReleaseParser.parse(releaseData(buildNumber: buildNumber))
    }

    private func httpResponse(
        for request: URLRequest,
        statusCode: Int,
        headers: [String: String]? = nil,
        data: Data
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(request.url),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        ))
        return (response, data)
    }

    private func assertCheckError(
        _ expectedError: AppUpdateCheckError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await makeChecker().check(currentBuildNumber: "10")
            XCTFail("Expected check to fail", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AppUpdateCheckError, expectedError, file: file, line: line)
        }
    }

    private func assertValidationError(
        _ expectedError: InkletReleaseValidationError,
        _ message: String = "",
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), message, file: file, line: line) { error in
            XCTAssertEqual(error as? InkletReleaseValidationError, expectedError, file: file, line: line)
        }
    }
}

private final class MockGitHubReleaseURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (URLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        handler = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1

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
