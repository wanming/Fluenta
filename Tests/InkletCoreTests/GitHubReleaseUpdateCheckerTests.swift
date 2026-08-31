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
        XCTAssertEqual(
            InkletReleaseNotes.excerpt(String(repeating: "a", count: 900), limit: 900).count,
            800
        )
    }

    func testReleaseNotesCountsExtendedGraphemeClusters() {
        let family = "👨‍👩‍👧‍👦"

        XCTAssertEqual(InkletReleaseNotes.excerpt(family + "ab", limit: 2), family + "…")
    }

    func testReleaseNotesBoundsOneHugeCombiningGraphemeByScalarsAndBytes() {
        let hugeGrapheme = "a" + String(repeating: "\u{0301}", count: 20_000)

        let excerpt = InkletReleaseNotes.excerpt(hugeGrapheme)

        XCTAssertLessThanOrEqual(excerpt.count, 800)
        XCTAssertLessThanOrEqual(excerpt.unicodeScalars.count, 3_200)
        XCTAssertLessThanOrEqual(excerpt.utf8.count, 12_800)
        XCTAssertEqual(excerpt, "…")
    }

    func testReleaseNotesPreservesEmojiAndNewlinesWhileRemovingUnsafeControls() {
        let family = "👨‍👩‍👧‍👦"

        let excerpt = InkletReleaseNotes.excerpt(
            " First \(family)\r\nSecond\tline\u{0000}\u{202E}\u{2067} "
        )

        XCTAssertEqual(excerpt, "First \(family)\nSecond\tline")
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

    func testParserSanitizesAndBoundsUntrustedReleaseName() throws {
        let family = "👨‍👩‍👧‍👦"
        let hugeGrapheme = "a" + String(repeating: "\u{0301}", count: 20_000)

        let sanitized = try GitHubReleaseParser.parse(
            makeReleaseData(name: " \nInklet\u{0000}\u{202E}  \tBeta \(family)\n ")
        )
        let bounded = try GitHubReleaseParser.parse(
            makeReleaseData(name: "Inklet " + hugeGrapheme)
        )

        XCTAssertEqual(sanitized.name, "Inklet Beta \(family)")
        let boundedName = try XCTUnwrap(bounded.name)
        XCTAssertLessThanOrEqual(boundedName.count, 120)
        XCTAssertLessThanOrEqual(boundedName.unicodeScalars.count, 480)
        XCTAssertLessThanOrEqual(boundedName.utf8.count, 1_920)
        XCTAssertEqual(boundedName, "Inklet …")
    }

    func testParserDropsReleaseNameContainingOnlyWhitespaceAndUnsafeControls() throws {
        let release = try GitHubReleaseParser.parse(
            makeReleaseData(name: " \n\t\u{0000}\u{202E}\u{2067} ")
        )

        XCTAssertNil(release.name)
    }

    func testParserReplacesReleaseNameLineBreaksWithSpaces() throws {
        let release = try GitHubReleaseParser.parse(
            makeReleaseData(name: "Inklet\nBeta\tRelease")
        )

        XCTAssertEqual(release.name, "Inklet Beta Release")
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
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return try self.httpResponse(for: request, statusCode: 200, data: self.releaseData(buildNumber: 11))
        }

        let result = try await makeChecker().check(currentBuildNumber: "10")

        XCTAssertEqual(result, .updateAvailable(try expectedRelease(buildNumber: 11)))
        XCTAssertEqual(MockGitHubReleaseURLProtocol.requestCount, 1)
    }

    func testDefaultSessionConfigurationDisablesPersistentPrivacySurfaces() {
        let configuration = GitHubReleaseUpdateChecker.makeSessionConfiguration()

        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, URLRequest.CachePolicy.reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 15)
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

    func testAuthenticationDelegateAllowsServerTrustAndCancelsOtherChallenges() throws {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "https://api.github.com/repos/wanming/Inklet/releases/latest")))

        let cases: [(String, URLSession.AuthChallengeDisposition)] = [
            (NSURLAuthenticationMethodServerTrust, .performDefaultHandling),
            (NSURLAuthenticationMethodHTTPBasic, .cancelAuthenticationChallenge),
            (NSURLAuthenticationMethodHTTPDigest, .cancelAuthenticationChallenge),
            (NSURLAuthenticationMethodClientCertificate, .cancelAuthenticationChallenge)
        ]

        for (authenticationMethod, expectedDisposition) in cases {
            let delegate = RedirectRejectingDelegate()
            let protectionSpace = URLProtectionSpace(
                host: "api.github.com",
                port: 443,
                protocol: "https",
                realm: nil,
                authenticationMethod: authenticationMethod
            )
            let challenge = URLAuthenticationChallenge(
                protectionSpace: protectionSpace,
                proposedCredential: nil,
                previousFailureCount: 0,
                failureResponse: nil,
                error: nil,
                sender: MockAuthenticationChallengeSender()
            )
            let result = AuthenticationChallengeResult()

            delegate.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                result.record(disposition: disposition, credential: credential)
            }

            XCTAssertEqual(result.disposition, expectedDisposition)
            XCTAssertNil(result.credential)
            XCTAssertEqual(
                delegate.didRejectAuthentication,
                expectedDisposition == .cancelAuthenticationChallenge
            )
        }
    }

    func testSessionAuthenticationDelegateAllowsServerTrustAndCancelsOtherChallenges() throws {
        let session = URLSession(configuration: .ephemeral)
        let cases: [(String, URLSession.AuthChallengeDisposition)] = [
            (NSURLAuthenticationMethodServerTrust, .performDefaultHandling),
            (NSURLAuthenticationMethodClientCertificate, .cancelAuthenticationChallenge)
        ]

        for (authenticationMethod, expectedDisposition) in cases {
            let delegate = RedirectRejectingDelegate()
            let sessionDelegate: URLSessionDelegate = delegate
            let protectionSpace = URLProtectionSpace(
                host: "api.github.com",
                port: 443,
                protocol: "https",
                realm: nil,
                authenticationMethod: authenticationMethod
            )
            let challenge = URLAuthenticationChallenge(
                protectionSpace: protectionSpace,
                proposedCredential: nil,
                previousFailureCount: 0,
                failureResponse: nil,
                error: nil,
                sender: MockAuthenticationChallengeSender()
            )
            let result = AuthenticationChallengeResult()

            sessionDelegate.urlSession?(session, didReceive: challenge) { disposition, credential in
                result.record(disposition: disposition, credential: credential)
            }

            XCTAssertEqual(result.disposition, expectedDisposition)
            XCTAssertNil(result.credential)
            XCTAssertEqual(
                delegate.didRejectAuthentication,
                expectedDisposition == .cancelAuthenticationChallenge
            )
        }
    }

    func testRejectedAuthenticationMapsCancelledTransportToServiceUnavailable() async throws {
        let endpoint = try XCTUnwrap(
            URL(string: "https://api.github.com/repos/wanming/Inklet/releases/latest")
        )
        let loader = BoundedHTTPResponseLoader(
            expectedURL: endpoint,
            maximumResponseSize: 1_048_576
        )
        let delegateSession = URLSession(configuration: .ephemeral)
        let delegateTask = delegateSession.dataTask(with: endpoint)
        defer {
            delegateTask.cancel()
            delegateSession.invalidateAndCancel()
        }
        let protectionSpace = URLProtectionSpace(
            host: "api.github.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: MockAuthenticationChallengeSender()
        )
        let challengeResult = AuthenticationChallengeResult()
        MockGitHubReleaseURLProtocol.onStart = {
            loader.urlSession(
                delegateSession,
                task: delegateTask,
                didReceive: challenge
            ) { disposition, credential in
                challengeResult.record(disposition: disposition, credential: credential)
            }
        }
        MockGitHubReleaseURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubReleaseURLProtocol.self]
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 5

        do {
            _ = try await loader.load(
                request: request,
                configuration: configuration,
                timeoutInterval: 5
            )
            XCTFail("Expected rejected authentication to fail the request")
        } catch {
            XCTAssertEqual(error as? AppUpdateCheckError, .serviceUnavailable)
        }

        XCTAssertEqual(challengeResult.disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(challengeResult.credential)
    }

    func testCheckRejectsRedirectWithoutFollowUpRequest() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.github.com/repos/wanming/Inklet/releases/latest"))
        let redirectedURL = try XCTUnwrap(URL(string: "https://example.invalid/redirected-release"))
        MockGitHubReleaseURLProtocol.redirect = try MockGitHubReleaseURLProtocol.Redirect(
            request: URLRequest(url: redirectedURL),
            response: XCTUnwrap(HTTPURLResponse(
                url: endpoint,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": redirectedURL.absoluteString]
            ))
        )
        MockGitHubReleaseURLProtocol.handler = { _ in
            XCTFail("The checker must not follow a redirect")
            throw URLError(.badServerResponse)
        }

        await assertCheckError(.serviceUnavailable)

        XCTAssertEqual(MockGitHubReleaseURLProtocol.requestCount, 1)
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

    func testCheckRejectsSuccessResponseFromDifferentURL() async throws {
        let unexpectedURL = try XCTUnwrap(URL(string: "https://example.invalid/releases/latest"))
        MockGitHubReleaseURLProtocol.handler = { request in
            try self.httpResponse(
                for: request,
                responseURL: unexpectedURL,
                statusCode: 200,
                data: self.releaseData(buildNumber: 11)
            )
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

    func testResponseLoaderRejectsDeclaredOversizeBeforeBodyDelivery() throws {
        let oversizedLength = 1_048_577
        let endpoint = try XCTUnwrap(URL(string: "https://api.github.com/repos/wanming/Inklet/releases/latest"))
        let loader = BoundedHTTPResponseLoader(expectedURL: endpoint, maximumResponseSize: 1_048_576)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: endpoint)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "\(oversizedLength)"]
        ))
        let result = ResponseDispositionResult()

        loader.urlSession(session, dataTask: task, didReceive: response) { disposition in
            result.record(disposition)
        }

        XCTAssertEqual(result.disposition, .cancel)
    }

    func testResponseLoaderRejectsNonSuccessStatusBeforeLargeErrorBodyDelivery() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.github.com/repos/wanming/Inklet/releases/latest"))
        let loader = BoundedHTTPResponseLoader(expectedURL: endpoint, maximumResponseSize: 1_048_576)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: endpoint)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: endpoint,
            statusCode: 500,
            httpVersion: nil,
            headerFields: ["Content-Length": "1048577"]
        ))
        let result = ResponseDispositionResult()

        loader.urlSession(session, dataTask: task, didReceive: response) { disposition in
            result.record(disposition)
        }

        XCTAssertEqual(result.disposition, .cancel)
    }

    func testResponseLoaderRejectsNonIdentityContentEncodingBeforeBodyDelivery() throws {
        for contentEncoding in ["gzip", " BR ", "DefLaTe", "identity, gzip"] {
            XCTAssertEqual(
                try responseDisposition(contentEncoding: contentEncoding),
                .cancel,
                "Expected \(contentEncoding) to be rejected before body delivery"
            )
        }
    }

    func testResponseLoaderAllowsAbsentOrIdentityContentEncoding() throws {
        for contentEncoding in [nil, "identity", " IDENTITY "] as [String?] {
            XCTAssertEqual(
                try responseDisposition(contentEncoding: contentEncoding),
                .allow,
                "Expected \(contentEncoding ?? "an absent header") to be accepted"
            )
        }
    }

    func testCheckCancelsUnknownLengthBodyAtFirstByteOverLimit() async throws {
        let maximumResponseSize = 1_048_576
        let requestStopped = expectation(description: "oversized request stopped")
        MockGitHubReleaseURLProtocol.onStop = {
            requestStopped.fulfill()
        }
        MockGitHubReleaseURLProtocol.streamHandler = { request in
            let response = try self.httpResponse(
                for: request,
                statusCode: 200,
                data: Data()
            ).0
            return MockGitHubReleaseURLProtocol.Stream(
                response: response,
                chunks: [
                    Data(repeating: 65, count: maximumResponseSize),
                    Data([66]),
                    Data(repeating: 67, count: 64 * 1_024)
                ],
                interval: 0.1
            )
        }

        await assertCheckError(.invalidResponse)
        await fulfillment(of: [requestStopped], timeout: 1)

        XCTAssertEqual(MockGitHubReleaseURLProtocol.sentBodyByteCount, maximumResponseSize + 1)
        XCTAssertEqual(MockGitHubReleaseURLProtocol.sentBodyChunkCount, 2)
        XCTAssertEqual(MockGitHubReleaseURLProtocol.stopLoadingCount, 1)
    }

    func testCheckRejectsSingleOversizedIdentityCallbackBeforeAnyLaterChunk() async throws {
        let maximumResponseSize = 1_048_576
        let requestStopped = expectation(description: "oversized callback stopped")
        MockGitHubReleaseURLProtocol.onStop = {
            requestStopped.fulfill()
        }
        MockGitHubReleaseURLProtocol.streamHandler = { request in
            let response = try self.httpResponse(
                for: request,
                statusCode: 200,
                headers: ["Content-Encoding": "identity"],
                data: Data()
            ).0
            return MockGitHubReleaseURLProtocol.Stream(
                response: response,
                chunks: [
                    Data(repeating: 65, count: maximumResponseSize + 1),
                    Data(repeating: 66, count: 64 * 1_024)
                ],
                interval: 0.1
            )
        }

        await assertCheckError(.invalidResponse)
        await fulfillment(of: [requestStopped], timeout: 1)

        XCTAssertEqual(MockGitHubReleaseURLProtocol.sentBodyByteCount, maximumResponseSize + 1)
        XCTAssertEqual(MockGitHubReleaseURLProtocol.sentBodyChunkCount, 1)
        XCTAssertEqual(MockGitHubReleaseURLProtocol.stopLoadingCount, 1)
    }

    func testProtocolHarnessDoesNotDeliverChunkAfterStopLoading() async throws {
        let deliveryReady = expectation(description: "chunk ready for delivery")
        let requestStopped = expectation(description: "request stopped")
        let unexpectedDelivery = expectation(description: "chunk delivered after stop")
        unexpectedDelivery.isInverted = true
        let deliveryGate = DispatchSemaphore(value: 0)
        MockGitHubReleaseURLProtocol.onStop = {
            requestStopped.fulfill()
        }
        MockGitHubReleaseURLProtocol.streamHandler = { request in
            let response = try self.httpResponse(
                for: request,
                statusCode: 200,
                data: Data()
            ).0
            return MockGitHubReleaseURLProtocol.Stream(
                response: response,
                chunks: [Data([65])],
                beforeEachChunk: {
                    deliveryReady.fulfill()
                    deliveryGate.wait()
                },
                afterEachChunk: {
                    unexpectedDelivery.fulfill()
                }
            )
        }
        let checker = makeChecker()
        let checkTask = Task {
            try await checker.check(currentBuildNumber: "10")
        }

        await fulfillment(of: [deliveryReady], timeout: 1)
        checkTask.cancel()
        await fulfillment(of: [requestStopped], timeout: 1)
        deliveryGate.signal()
        await fulfillment(of: [unexpectedDelivery], timeout: 0.1)

        do {
            _ = try await checkTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(MockGitHubReleaseURLProtocol.sentBodyByteCount, 0)
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
            try self.httpResponse(
                for: request,
                statusCode: 200,
                headers: ["Content-Length": "\(maximumResponseSize)"],
                data: data
            )
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

    func testCheckEnforcesTotalDeadlineDespiteSlowTrickle() async throws {
        let responseData = try releaseData(buildNumber: 11)
        let requestStopped = expectation(description: "deadline stops request")
        MockGitHubReleaseURLProtocol.onStop = {
            requestStopped.fulfill()
        }
        let chunkSize = max(1, responseData.count / 12)
        let chunks = stride(from: 0, to: responseData.count, by: chunkSize).map { offset in
            responseData.subdata(in: offset..<min(offset + chunkSize, responseData.count))
        }
        MockGitHubReleaseURLProtocol.streamHandler = { request in
            let response = try self.httpResponse(
                for: request,
                statusCode: 200,
                data: Data()
            ).0
            return MockGitHubReleaseURLProtocol.Stream(
                response: response,
                chunks: chunks,
                interval: 0.08
            )
        }

        do {
            _ = try await makeChecker(timeoutInterval: 0.25).check(currentBuildNumber: "10")
            XCTFail("Expected the total deadline to stop a trickled response")
        } catch {
            XCTAssertEqual(error as? AppUpdateCheckError, .networkUnavailable)
        }
        await fulfillment(of: [requestStopped], timeout: 1)

        XCTAssertLessThan(MockGitHubReleaseURLProtocol.sentBodyByteCount, responseData.count)
        XCTAssertEqual(MockGitHubReleaseURLProtocol.stopLoadingCount, 1)
    }

    func testResponseLoaderDeadlinePrecedesLongResourceTimeout() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.github.com/repos/wanming/Inklet/releases/latest"))
        let responseData = try releaseData(buildNumber: 11)
        let chunkSize = max(1, responseData.count / 12)
        let chunks = stride(from: 0, to: responseData.count, by: chunkSize).map { offset in
            responseData.subdata(in: offset..<min(offset + chunkSize, responseData.count))
        }
        let requestStopped = expectation(description: "monotonic deadline stops request")
        MockGitHubReleaseURLProtocol.onStop = {
            requestStopped.fulfill()
        }
        MockGitHubReleaseURLProtocol.streamHandler = { request in
            let response = try self.httpResponse(
                for: request,
                statusCode: 200,
                data: Data()
            ).0
            return MockGitHubReleaseURLProtocol.Stream(
                response: response,
                chunks: chunks,
                interval: 0.08
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubReleaseURLProtocol.self]
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 5
        let loader = BoundedHTTPResponseLoader(
            expectedURL: endpoint,
            maximumResponseSize: 1_048_576
        )

        do {
            _ = try await loader.load(
                request: request,
                configuration: configuration,
                timeoutInterval: 0.25
            )
            XCTFail("Expected the monotonic deadline to stop a trickled response")
        } catch {
            XCTAssertTrue(error is UpdateCheckDeadlineExceeded)
        }
        await fulfillment(of: [requestStopped], timeout: 1)

        XCTAssertLessThan(MockGitHubReleaseURLProtocol.sentBodyByteCount, responseData.count)
        XCTAssertEqual(MockGitHubReleaseURLProtocol.stopLoadingCount, 1)
    }

    func testResponseCompletionAfterDeadlineFailsBeforeDeadlineSleeperRuns() async throws {
        let endpoint = try XCTUnwrap(
            URL(string: "https://api.github.com/repos/wanming/Inklet/releases/latest")
        )
        let monotonicTime = ControllableMonotonicTime()
        MockGitHubReleaseURLProtocol.handler = { request in
            monotonicTime.advance(by: .seconds(3_601))
            return try self.httpResponse(
                for: request,
                statusCode: 200,
                data: self.releaseData(buildNumber: 11)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubReleaseURLProtocol.self]
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 3_600
        let loader = BoundedHTTPResponseLoader(
            expectedURL: endpoint,
            maximumResponseSize: 1_048_576,
            monotonicNow: { monotonicTime.now }
        )
        do {
            _ = try await loader.load(
                request: request,
                configuration: configuration,
                timeoutInterval: 3_600
            )
            XCTFail("Expected completion after the deadline to fail")
        } catch {
            XCTAssertTrue(error is UpdateCheckDeadlineExceeded)
        }
    }

    func testParentCancellationAfterDeadlineRemainsCancellation() async throws {
        let endpoint = try XCTUnwrap(
            URL(string: "https://api.github.com/repos/wanming/Inklet/releases/latest")
        )
        let monotonicTime = ControllableMonotonicTime()
        let requestStarted = expectation(description: "request started")
        let requestStopped = expectation(description: "request stopped")
        MockGitHubReleaseURLProtocol.pending = true
        MockGitHubReleaseURLProtocol.onStart = {
            requestStarted.fulfill()
        }
        MockGitHubReleaseURLProtocol.onStop = {
            requestStopped.fulfill()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubReleaseURLProtocol.self]
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 60
        let loader = BoundedHTTPResponseLoader(
            expectedURL: endpoint,
            maximumResponseSize: 1_048_576,
            monotonicNow: { monotonicTime.now }
        )
        let loadTask = Task {
            try await loader.load(
                request: request,
                configuration: configuration,
                timeoutInterval: 60
            )
        }

        await fulfillment(of: [requestStarted], timeout: 1)
        monotonicTime.advance(by: .seconds(61))
        loadTask.cancel()

        do {
            _ = try await loadTask.value
            XCTFail("Expected parent cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        await fulfillment(of: [requestStopped], timeout: 1)
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

    func testCheckCancellationStopsPendingRequest() async {
        let requestStarted = expectation(description: "request started")
        let requestStopped = expectation(description: "request stopped")
        MockGitHubReleaseURLProtocol.pending = true
        MockGitHubReleaseURLProtocol.onStart = {
            requestStarted.fulfill()
        }
        MockGitHubReleaseURLProtocol.onStop = {
            requestStopped.fulfill()
        }
        let checker = makeChecker()
        let checkTask = Task {
            try await checker.check(currentBuildNumber: "10")
        }

        await fulfillment(of: [requestStarted], timeout: 1)
        checkTask.cancel()

        do {
            _ = try await checkTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        await fulfillment(of: [requestStopped], timeout: 1)
        XCTAssertEqual(MockGitHubReleaseURLProtocol.requestCount, 1)
        XCTAssertEqual(MockGitHubReleaseURLProtocol.stopLoadingCount, 1)
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

    private func makeChecker(timeoutInterval: TimeInterval) -> GitHubReleaseUpdateChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubReleaseURLProtocol.self]
        return GitHubReleaseUpdateChecker(
            session: URLSession(configuration: configuration),
            timeoutInterval: timeoutInterval
        )
    }

    private func responseDisposition(
        contentEncoding: String?
    ) throws -> URLSession.ResponseDisposition? {
        let endpoint = try XCTUnwrap(
            URL(string: "https://api.github.com/repos/wanming/Inklet/releases/latest")
        )
        let loader = BoundedHTTPResponseLoader(
            expectedURL: endpoint,
            maximumResponseSize: 1_048_576
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: endpoint)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        var headerFields: [String: String] = [:]
        headerFields["Content-Encoding"] = contentEncoding
        let response = try XCTUnwrap(HTTPURLResponse(
            url: endpoint,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headerFields
        ))
        let result = ResponseDispositionResult()

        loader.urlSession(session, dataTask: task, didReceive: response) { disposition in
            result.record(disposition)
        }

        return result.disposition
    }

    private func releaseData(buildNumber: Int) throws -> Data {
        try makeReleaseData(tagName: "v1.2.3-\(buildNumber)")
    }

    private func expectedRelease(buildNumber: Int) throws -> InkletRelease {
        try GitHubReleaseParser.parse(releaseData(buildNumber: buildNumber))
    }

    private func httpResponse(
        for request: URLRequest,
        responseURL: URL? = nil,
        statusCode: Int,
        headers: [String: String]? = nil,
        data: Data
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: responseURL ?? XCTUnwrap(request.url),
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

private final class MockGitHubReleaseURLProtocol: URLProtocol, @unchecked Sendable {
    struct Redirect {
        let request: URLRequest
        let response: HTTPURLResponse
    }

    struct Stream {
        let response: URLResponse
        let chunks: [Data]
        let interval: TimeInterval
        let beforeEachChunk: (@Sendable () -> Void)?
        let afterEachChunk: (@Sendable () -> Void)?

        init(
            response: URLResponse,
            chunks: [Data],
            interval: TimeInterval = 0,
            beforeEachChunk: (@Sendable () -> Void)? = nil,
            afterEachChunk: (@Sendable () -> Void)? = nil
        ) {
            self.response = response
            self.chunks = chunks
            self.interval = interval
            self.beforeEachChunk = beforeEachChunk
            self.afterEachChunk = afterEachChunk
        }
    }

    private enum LoadingAction {
        case pending
        case redirect(Redirect)
        case stream((URLRequest) throws -> Stream)
        case handler((URLRequest) throws -> (URLResponse, Data))
        case missingHandler
    }

    private final class Generation: @unchecked Sendable {
        private let lock = NSLock()
        private var storedHandler: ((URLRequest) throws -> (URLResponse, Data))?
        private var storedStreamHandler: ((URLRequest) throws -> Stream)?
        private var storedRequestCount = 0
        private var storedRedirect: Redirect?
        private var storedPending = false
        private var storedOnStart: (() -> Void)?
        private var storedOnStop: (() -> Void)?
        private var storedStopLoadingCount = 0
        private var storedSentBodyByteCount = 0
        private var storedSentBodyChunkCount = 0

        var handler: ((URLRequest) throws -> (URLResponse, Data))? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedHandler
            }
            set {
                lock.lock()
                storedHandler = newValue
                lock.unlock()
            }
        }

        var streamHandler: ((URLRequest) throws -> Stream)? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedStreamHandler
            }
            set {
                lock.lock()
                storedStreamHandler = newValue
                lock.unlock()
            }
        }

        var requestCount: Int {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedRequestCount
            }
            set {
                lock.lock()
                storedRequestCount = newValue
                lock.unlock()
            }
        }

        var redirect: Redirect? {
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

        var pending: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedPending
            }
            set {
                lock.lock()
                storedPending = newValue
                lock.unlock()
            }
        }

        var onStart: (() -> Void)? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedOnStart
            }
            set {
                lock.lock()
                storedOnStart = newValue
                lock.unlock()
            }
        }

        var onStop: (() -> Void)? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedOnStop
            }
            set {
                lock.lock()
                storedOnStop = newValue
                lock.unlock()
            }
        }

        var stopLoadingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedStopLoadingCount
        }

        var sentBodyByteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedSentBodyByteCount
        }

        var sentBodyChunkCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedSentBodyChunkCount
        }

        func beginLoading() -> LoadingAction {
            let action: LoadingAction
            let onStart: (() -> Void)?

            lock.lock()
            storedRequestCount += 1
            onStart = storedOnStart
            if storedPending {
                action = .pending
            } else if let redirect = storedRedirect {
                storedRedirect = nil
                action = .redirect(redirect)
            } else if let streamHandler = storedStreamHandler {
                action = .stream(streamHandler)
            } else if let handler = storedHandler {
                action = .handler(handler)
            } else {
                action = .missingHandler
            }
            lock.unlock()

            onStart?()
            return action
        }

        func completeLoading() {
            lock.lock()
            storedHandler = nil
            storedStreamHandler = nil
            storedOnStart = nil
            storedOnStop = nil
            storedRedirect = nil
            storedPending = false
            lock.unlock()
        }

        func stopLoading() {
            let onStop: (() -> Void)?

            lock.lock()
            storedStopLoadingCount += 1
            onStop = storedOnStop
            storedHandler = nil
            storedStreamHandler = nil
            storedOnStart = nil
            storedOnStop = nil
            storedRedirect = nil
            storedPending = false
            lock.unlock()

            onStop?()
        }

        func recordBodyDelivery(_ byteCount: Int) {
            lock.lock()
            storedSentBodyByteCount += byteCount
            storedSentBodyChunkCount += 1
            lock.unlock()
        }
    }

    private static let generationLock = NSLock()
    nonisolated(unsafe) private static var currentGeneration = Generation()

    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (URLResponse, Data))? {
        get { currentGenerationSnapshot().handler }
        set { currentGenerationSnapshot().handler = newValue }
    }

    nonisolated(unsafe) static var streamHandler: ((URLRequest) throws -> Stream)? {
        get { currentGenerationSnapshot().streamHandler }
        set { currentGenerationSnapshot().streamHandler = newValue }
    }

    nonisolated(unsafe) static var requestCount: Int {
        get { currentGenerationSnapshot().requestCount }
        set { currentGenerationSnapshot().requestCount = newValue }
    }

    nonisolated(unsafe) static var redirect: Redirect? {
        get { currentGenerationSnapshot().redirect }
        set { currentGenerationSnapshot().redirect = newValue }
    }

    nonisolated(unsafe) static var pending: Bool {
        get { currentGenerationSnapshot().pending }
        set { currentGenerationSnapshot().pending = newValue }
    }

    nonisolated(unsafe) static var onStart: (() -> Void)? {
        get { currentGenerationSnapshot().onStart }
        set { currentGenerationSnapshot().onStart = newValue }
    }

    nonisolated(unsafe) static var onStop: (() -> Void)? {
        get { currentGenerationSnapshot().onStop }
        set { currentGenerationSnapshot().onStop = newValue }
    }

    nonisolated(unsafe) static var stopLoadingCount: Int {
        currentGenerationSnapshot().stopLoadingCount
    }

    nonisolated(unsafe) static var sentBodyByteCount: Int {
        currentGenerationSnapshot().sentBodyByteCount
    }

    nonisolated(unsafe) static var sentBodyChunkCount: Int {
        currentGenerationSnapshot().sentBodyChunkCount
    }

    private let instanceLock = NSLock()
    private var capturedGeneration: Generation?
    private var stopped = false
    private var deliveryInProgress = false
    private var stopReported = false
    private let deliveryQueue = DispatchQueue(label: "MockGitHubReleaseURLProtocol.delivery")

    static func reset() {
        generationLock.lock()
        currentGeneration = Generation()
        generationLock.unlock()
    }

    private static func currentGenerationSnapshot() -> Generation {
        generationLock.lock()
        defer { generationLock.unlock() }
        return currentGeneration
    }

    private func captureCurrentGeneration() -> Generation {
        let generation = Self.currentGenerationSnapshot()
        instanceLock.lock()
        capturedGeneration = generation
        instanceLock.unlock()
        return generation
    }

    private func capturedGenerationSnapshot() -> Generation? {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        return capturedGeneration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let generation = captureCurrentGeneration()

        switch generation.beginLoading() {
        case .pending:
            return
        case .redirect(let redirect):
            client?.urlProtocol(self, wasRedirectedTo: redirect.request, redirectResponse: redirect.response)
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            generation.completeLoading()
            return
        case .stream(let handler):
            do {
                let stream = try handler(request)
                client?.urlProtocol(self, didReceive: stream.response, cacheStoragePolicy: .notAllowed)
                scheduleDelivery(of: stream, chunkIndex: 0, delay: 0, generation: generation)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                generation.completeLoading()
            }
            return
        case .missingHandler:
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            generation.completeLoading()
            return
        case .handler(let handler):
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            generation.completeLoading()
        }
    }

    override func stopLoading() {
        let generation = capturedGenerationSnapshot()
        let shouldReportStop: Bool

        instanceLock.lock()
        if stopped {
            shouldReportStop = false
        } else {
            stopped = true
            shouldReportStop = !deliveryInProgress
            if shouldReportStop {
                stopReported = true
            }
        }
        instanceLock.unlock()

        if shouldReportStop {
            generation?.stopLoading()
        }
    }

    private func scheduleDelivery(
        of stream: Stream,
        chunkIndex: Int,
        delay: TimeInterval,
        generation: Generation
    ) {
        deliveryQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                return
            }
            guard chunkIndex < stream.chunks.count else {
                guard self.canFinish else {
                    return
                }
                self.client?.urlProtocolDidFinishLoading(self)
                generation.completeLoading()
                return
            }

            stream.beforeEachChunk?()
            guard self.beginDelivery() else {
                return
            }

            let chunk = stream.chunks[chunkIndex]
            generation.recordBodyDelivery(chunk.count)
            self.client?.urlProtocol(self, didLoad: chunk)
            stream.afterEachChunk?()
            guard self.endDelivery(generation: generation) else {
                return
            }
            self.scheduleDelivery(
                of: stream,
                chunkIndex: chunkIndex + 1,
                delay: stream.interval,
                generation: generation
            )
        }
    }

    private func beginDelivery() -> Bool {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        guard !stopped else {
            return false
        }
        deliveryInProgress = true
        return true
    }

    private func endDelivery(generation: Generation) -> Bool {
        let shouldReportStop: Bool
        let shouldContinue: Bool

        instanceLock.lock()
        deliveryInProgress = false
        shouldContinue = !stopped
        shouldReportStop = stopped && !stopReported
        if shouldReportStop {
            stopReported = true
        }
        instanceLock.unlock()

        if shouldReportStop {
            generation.stopLoading()
        }
        return shouldContinue
    }

    private var canFinish: Bool {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        return !stopped
    }
}

private final class AuthenticationChallengeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDisposition: URLSession.AuthChallengeDisposition?
    private var storedCredential: URLCredential?

    var disposition: URLSession.AuthChallengeDisposition? {
        lock.lock()
        defer { lock.unlock() }
        return storedDisposition
    }

    var credential: URLCredential? {
        lock.lock()
        defer { lock.unlock() }
        return storedCredential
    }

    func record(disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
        lock.lock()
        storedDisposition = disposition
        storedCredential = credential
        lock.unlock()
    }
}

private final class ResponseDispositionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDisposition: URLSession.ResponseDisposition?

    var disposition: URLSession.ResponseDisposition? {
        lock.lock()
        defer { lock.unlock() }
        return storedDisposition
    }

    func record(_ disposition: URLSession.ResponseDisposition) {
        lock.lock()
        storedDisposition = disposition
        lock.unlock()
    }
}

private final class ControllableMonotonicTime: @unchecked Sendable {
    private let lock = NSLock()
    private var storedNow = ContinuousClock().now

    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return storedNow
    }

    func advance(by duration: Duration) {
        lock.lock()
        storedNow = storedNow.advanced(by: duration)
        lock.unlock()
    }
}

private final class MockAuthenticationChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}

    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
