import Foundation
import XCTest

final class UpdateCheckDocumentationTests: XCTestCase {
    func testReadmesDescribeCheckOnlyGitHubUpdateBehavior() throws {
        let english = try markdownSection(
            heading: "## Updates",
            in: try document(named: "README.md")
        )
        assertContains(
            [
                "GitHub Releases",
                "latest stable release",
                "24 hours",
                "Inklet.dmg",
                "View on GitHub",
                "never downloads or installs updates automatically",
                "Check for Updates",
                "Inklet Local",
                "never schedules automatic checks",
                "Automatic check failures are silent",
                "Retry",
                "writing",
                "voice",
                "Selection Actions",
                "migration"
            ],
            in: english,
            documentName: "README.md Updates"
        )

        let chinese = try markdownSection(
            heading: "## 更新",
            in: try document(named: "README.zh-CN.md")
        )
        assertContains(
            [
                "GitHub Releases",
                "最新稳定版",
                "24 小时",
                "Inklet.dmg",
                "在 GitHub 上查看",
                "不会自动下载或安装更新",
                "检查更新",
                "Inklet Local",
                "不会安排自动检查",
                "自动检查失败时保持静默",
                "重试",
                "写作",
                "语音",
                "选区动作",
                "迁移"
            ],
            in: chinese,
            documentName: "README.zh-CN.md 更新"
        )
    }

    func testReadmesListEverySupportedInterfaceLanguage() throws {
        let english = try markdownSection(
            heading: "## What It Does",
            in: try document(named: "README.md")
        )
        assertContains(
            [
                "English",
                "Simplified Chinese",
                "Traditional Chinese",
                "Japanese",
                "Korean",
                "Spanish",
                "French",
                "German",
                "Portuguese",
                "Italian"
            ],
            in: english,
            documentName: "README.md What It Does"
        )

        let chinese = try markdownSection(
            heading: "## 功能",
            in: try document(named: "README.zh-CN.md")
        )
        assertContains(
            [
                "英文",
                "简体中文",
                "繁体中文",
                "日文",
                "韩文",
                "西班牙文",
                "法文",
                "德文",
                "葡萄牙文",
                "意大利文"
            ],
            in: chinese,
            documentName: "README.zh-CN.md 功能"
        )
    }

    func testPrivacyPolicyDisclosesOnlyPublicReleaseMetadataRequest() throws {
        let privacyPolicy = try document(named: "docs/privacy-policy.md")
        XCTAssertTrue(
            privacyPolicy.contains("Last updated: August 30, 2026"),
            "Privacy policy must carry the update-check disclosure date"
        )

        let updateChecks = try markdownSection(
            heading: "## Update Checks",
            in: privacyPolicy
        )
        assertContains(
            [
                "GitHub Releases",
                "public metadata",
                "latest stable Inklet release",
                "24 hours",
                "Inklet Local",
                "manual",
                "ordinary connection metadata",
                "prompts",
                "text",
                "audio",
                "History",
                "API keys",
                "provider configuration",
                "settings",
                "Inklet.dmg",
                "never downloads or installs an update automatically"
            ],
            in: updateChecks,
            documentName: "privacy policy Update Checks"
        )
    }

    func testManualChecklistCoversUpdateCheckMatrix() throws {
        let updateChecks = try markdownSection(
            heading: "## Update Checks",
            in: try document(named: "docs/manual-test-checklist.md")
        )
        assertContains(
            [
                "production",
                "Inklet Local",
                "automated fixtures",
                "swift test --filter GitHubReleaseUpdateCheckerTests",
                "malformed",
                "no live-app fixture switch",
                "text behavior only",
                "do not verify alert layout or readability",
                "without a fixture-capable app build",
                "empty-note fallback layout",
                "long-note visual readability",
                "exact note shape",
                "genuinely newer stable release",
                "remain unverified",
                "not passed",
                "up to date",
                "newer",
                "draft",
                "prerelease",
                "missing",
                "non-uploaded",
                "uploaded `Inklet.dmg`",
                "exact GitHub Release URL",
                "Later",
                "no DMG",
                "offline",
                "Retry",
                "silent",
                "24 hours",
                "writing",
                "voice",
                "Selection Actions",
                "migration",
                "menu",
                "modal",
                "exactly once",
                "long release notes",
                "English",
                "Simplified Chinese",
                "Traditional Chinese",
                "Japanese",
                "Korean",
                "Spanish",
                "French",
                "German",
                "Portuguese",
                "Italian"
            ],
            in: updateChecks,
            documentName: "manual checklist Update Checks"
        )
    }

    func testPublicDocumentationRejectsAutomaticDownloadOrInstallationClaims() throws {
        for relativePath in [
            "README.md",
            "README.zh-CN.md",
            "docs/privacy-policy.md",
            "docs/manual-test-checklist.md"
        ] {
            assertDoesNotContainAutomaticDownloadOrInstallationClaim(
                try document(named: relativePath),
                documentName: relativePath
            )
        }
    }

    func testAutomaticUpdateClaimMatcherDistinguishesAffirmativeAndNegativeCopy() {
        let forbiddenClaims = [
            "Inklet automatically downloads and installs updates.",
            "Inklet will automatically install an update.",
            "Inklet downloads updates automatically.",
            "Inklet will download and install updates automatically.",
            "New Inklet versions are downloaded and installed automatically.",
            "Updates download automatically in Inklet.",
            "Updates are downloaded automatically.",
            "Inklet updates are automatically installed.",
            "Inklet 会自动下载并安装更新。",
            "Inklet 将自动安装更新。",
            "Inklet自动下载更新。",
            "本应用会自动下载并安装 Inklet 更新。",
            "更新会自动下载并安装。"
        ]
        for claim in forbiddenClaims {
            XCTAssertNotNil(
                automaticDownloadOrInstallationClaim(in: claim),
                "Matcher did not reject affirmative claim: \(claim)"
            )
        }

        let allowedClaims = [
            "Inklet never downloads or installs updates automatically.",
            "Inklet does not automatically download or install updates.",
            "Inklet will not automatically install an update.",
            "Updates are not downloaded automatically.",
            "Inklet automatically downloads public release metadata.",
            "Inklet automatically downloads update metadata.",
            "Inklet automatically checks public release metadata.",
            "Inklet 不会自动下载或安装更新。",
            "Inklet 从不自动下载或安装更新。",
            "Inklet 会自动下载公开的 release 元数据。",
            "Inklet 会自动检查公开的 release 元数据。"
        ]
        for claim in allowedClaims {
            XCTAssertNil(
                automaticDownloadOrInstallationClaim(in: claim),
                "Matcher rejected negative claim: \(claim)"
            )
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private func document(named relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func markdownSection(heading: String, in document: String) throws -> String {
        let headingRange = try XCTUnwrap(
            document.range(of: "\(heading)\n"),
            "Missing Markdown heading \(heading)"
        )
        let contentStart = headingRange.upperBound
        let nextHeading = document.range(
            of: "\n## ",
            range: contentStart..<document.endIndex
        )?.lowerBound ?? document.endIndex
        return String(document[contentStart..<nextHeading])
    }

    private func assertContains(
        _ anchors: [String],
        in text: String,
        documentName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for anchor in anchors {
            XCTAssertNotNil(
                text.range(of: anchor, options: .caseInsensitive),
                "\(documentName) is missing required anchor: \(anchor)",
                file: file,
                line: line
            )
        }
    }

    private func assertDoesNotContainAutomaticDownloadOrInstallationClaim(
        _ text: String,
        documentName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let claim = automaticDownloadOrInstallationClaim(in: text) else {
            return
        }
        XCTFail(
            "\(documentName) contains a forbidden automatic-update claim: \(claim)",
            file: file,
            line: line
        )
    }

    private func automaticDownloadOrInstallationClaim(in text: String) -> String? {
        let englishPackage = #"(?:updates?(?!\s+metadata\b)|(?:(?:new|latest)\s+)?(?:Inklet\s+)?versions?(?!\s+metadata\b)|(?:Inklet\s+)?DMGs?|(?:Inklet\s+)?(?:update\s+)?packages?|(?:Inklet\s+)?installers?)"#
        let englishPackageWithArticle = #"(?:an?\s+|the\s+)?\#(englishPackage)"#
        let englishAppSubject = #"(?:Inklet|the\s+app|this\s+app)"#
        let englishVerb = #"(?:downloads?|installs?)"#
        let englishPastParticiple = #"(?:downloaded|installed)"#
        let chinesePackage = #"(?:Inklet\s*)?(?:(?:(?:新|最新)\s*)?版本(?!\s*(?:的\s*)?元数据)|更新(?!\s*元数据)|DMG|安装包|更新包|应用安装包)"#
        let chineseAppSubject = #"(?:Inklet|本应用|该应用|此应用)"#
        let chineseVerb = #"(?:下载|安装)"#
        let forbiddenClaimPatterns = [
            #"\b\#(englishAppSubject)\s+(?:(?:will|does|can)\s+)?automatically\s+\#(englishVerb)(?:\s+(?:and|or)\s+\#(englishVerb))?\s+\#(englishPackageWithArticle)\b"#,
            #"\b\#(englishAppSubject)\s+(?:(?:will|does|can)\s+)?\#(englishVerb)(?:\s+(?:and|or)\s+\#(englishVerb))?\s+\#(englishPackageWithArticle)\s+automatically\b"#,
            #"\b(?:an?\s+|the\s+)?\#(englishPackage)\s+(?:(?:(?:will|can)\s+)?\#(englishVerb)\s+automatically|(?:is|are|will\s+be|can\s+be)\s+(?:automatically\s+\#(englishPastParticiple)(?:\s+(?:and|or)\s+\#(englishPastParticiple))?|\#(englishPastParticiple)(?:\s+(?:and|or)\s+\#(englishPastParticiple))?\s+automatically))\b"#,
            #"(?im)(?:^|\n)\s*(?:[-*]\s*)?automatically\s+\#(englishVerb)(?:\s+(?:and|or)\s+\#(englishVerb))?\s+\#(englishPackageWithArticle)\b"#,
            #"\b\#(chineseAppSubject)\s*(?:(?:将会|会|将|可以)\s*)?自动\s*\#(chineseVerb)(?:\s*(?:并|和|或)\s*\#(chineseVerb))?\s*\#(chinesePackage)"#,
            #"\#(chinesePackage)\s*(?:(?:(?:将会|会|将|可以)\s*)?自动\s*\#(chineseVerb)(?:\s*(?:并|和|或)\s*\#(chineseVerb))?|(?:(?:将会|会|将|可以)\s*)?被\s*自动\s*\#(chineseVerb)(?:\s*(?:并|和|或)\s*\#(chineseVerb))?)"#,
            #"(?m)(?:^|\n)\s*(?:[-*]\s*)?自动\s*\#(chineseVerb)(?:\s*(?:并|和|或)\s*\#(chineseVerb))?\s*\#(chinesePackage)"#
        ]

        for pattern in forbiddenClaimPatterns {
            if let range = text.range(
                of: pattern,
                options: [.caseInsensitive, .regularExpression]
            ) {
                return String(text[range])
            }
        }
        return nil
    }
}
