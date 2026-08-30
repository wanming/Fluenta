import Foundation
import XCTest
@testable import InkletCore

final class GitHubReleaseUpdateCheckerTests: XCTestCase {
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
