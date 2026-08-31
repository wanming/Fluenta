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
}
