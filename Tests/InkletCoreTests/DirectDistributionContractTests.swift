import CoreFoundation
import Foundation
import XCTest

final class DirectDistributionContractTests: XCTestCase {
    func testPlistBooleanTrueRejectsNumericLookalikes() throws {
        let propertyList = try propertyList(from: Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
                <key>integer</key>
                <integer>1</integer>
                <key>real</key>
                <real>1.0</real>
                <key>boolean</key>
                <true/>
            </dict>
            </plist>
            """.utf8
        ))

        XCTAssertFalse(isTruePlistBoolean(propertyList["integer"]))
        XCTAssertFalse(isTruePlistBoolean(propertyList["real"]))
        XCTAssertTrue(isTruePlistBoolean(propertyList["boolean"]))
    }

    func testEntitlementsContainOnlyDirectDistributionMicrophoneAccess() throws {
        let entitlements = try propertyList(at: repositoryRoot
            .appendingPathComponent("StoreSupport/Inklet.entitlements"))
        let expected: [String: Any] = [
            "com.apple.security.device.audio-input": true
        ]

        XCTAssertEqual(entitlements as NSDictionary, expected as NSDictionary)
        XCTAssertTrue(isTruePlistBoolean(entitlements["com.apple.security.device.audio-input"]))

        let forbiddenKeys = [
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
            "com.apple.security.device.microphone",
            "com.apple.security.automation.apple-events",
            "com.apple.security.get-task-allow"
        ]
        for key in forbiddenKeys {
            XCTAssertNil(entitlements[key], "Direct distribution must not include \(key)")
        }
    }

    func testInfoPlistDeclaresOnlyMicrophonePrivacyUsage() throws {
        let infoPlist = try propertyList(at: repositoryRoot
            .appendingPathComponent("StoreSupport/Info.plist"))
        let microphoneUsageDescription = try XCTUnwrap(
            infoPlist["NSMicrophoneUsageDescription"] as? String
        )

        XCTAssertFalse(
            microphoneUsageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        XCTAssertNil(infoPlist["NSAppleEventsUsageDescription"])
    }

    func testAllLocalizedInfoPlistStringsDeclareOnlyMicrophonePrivacyUsage() throws {
        let localizationsRoot = repositoryRoot
            .appendingPathComponent("StoreSupport/InfoPlistStrings", isDirectory: true)
        let expectedLocalizationPaths: Set<String> = [
            "de.lproj/InfoPlist.strings",
            "en.lproj/InfoPlist.strings",
            "es.lproj/InfoPlist.strings",
            "fr.lproj/InfoPlist.strings",
            "it.lproj/InfoPlist.strings",
            "ja.lproj/InfoPlist.strings",
            "ko.lproj/InfoPlist.strings",
            "pt.lproj/InfoPlist.strings",
            "zh-Hans.lproj/InfoPlist.strings",
            "zh-Hant.lproj/InfoPlist.strings"
        ]
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: localizationsRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ))
        var localizationURLs: [URL] = []

        for case let fileURL as URL in enumerator
            where fileURL.lastPathComponent == "InfoPlist.strings"
        {
            let resourceValues = try fileURL.resourceValues(forKeys: resourceKeys)
            guard resourceValues.isRegularFile == true else {
                continue
            }
            localizationURLs.append(fileURL)
        }

        localizationURLs.sort { $0.path < $1.path }
        let discoveredLocalizationPaths = Set(localizationURLs.map { localizationURL in
            localizationURL.pathComponents
                .dropFirst(localizationsRoot.pathComponents.count)
                .joined(separator: "/")
        })
        let missingPaths = expectedLocalizationPaths.subtracting(discoveredLocalizationPaths)
        let unexpectedPaths = discoveredLocalizationPaths.subtracting(expectedLocalizationPaths)

        XCTAssertEqual(localizationURLs.count, 10)
        XCTAssertEqual(
            discoveredLocalizationPaths,
            expectedLocalizationPaths,
            """
            Localized InfoPlist.strings paths differ.
            Missing: \(missingPaths.sorted())
            Unexpected: \(unexpectedPaths.sorted())
            """
        )

        for localizationURL in localizationURLs {
            let localizedStrings = try propertyList(at: localizationURL)
            let microphoneUsageDescription = try XCTUnwrap(
                localizedStrings["NSMicrophoneUsageDescription"] as? String,
                "Missing microphone privacy copy in \(localizationURL.path)"
            )

            XCTAssertFalse(
                microphoneUsageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Empty microphone privacy copy in \(localizationURL.path)"
            )
            XCTAssertNil(
                localizedStrings["NSAppleEventsUsageDescription"],
                "Unexpected Apple Events privacy copy in \(localizationURL.path)"
            )
        }
    }

    func testPrivacyPolicyDeclaresRealtimeDictationContractWithExactUpdateDate() throws {
        let policy = try text(at: "docs/privacy-policy.md")
        let updateLines = policy.split(separator: "\n").filter {
            $0.hasPrefix("Last updated:")
        }

        XCTAssertEqual(updateLines, ["Last updated: August 30, 2026"])
        for required in [
            "Active microphone audio is streamed to OpenAI's Realtime transcription service as it is captured.",
            "one temporary local `.m4a` recovery recording",
            "only to the one file-transcription recovery attempt",
            "success, no speech, fallback success or failure, Escape, focus loss, popover closure, supersession, migration maintenance, and app termination",
            "does not log audio or transcript content, Authorization headers, microphone identifiers, or temporary file paths",
            "Audio is never placed on the clipboard or stored in History.",
            "An unprocessed dictated draft creates no History entry.",
            "Existing legacy Voice entries remain locally readable.",
            "Microphone permission is distinct from Accessibility permission",
            "finishing dictation does not insert text into another app",
        ] {
            XCTAssertTrue(policy.contains(required), required)
        }

        let distributionContract = try text(at: "scripts/test-direct-distribution.sh")
        XCTAssertTrue(distributionContract.contains("Last updated: August 30, 2026"))
        XCTAssertFalse(distributionContract.contains("Last updated: August 12, 2026"))
    }

    func testReadmesDescribeMergedHoldOnlyWritingDictationAndRejectStandaloneWorkflow() throws {
        let english = try text(at: "README.md")
        let chinese = try text(at: "README.zh-CN.md")
        let combined = english + "\n" + chinese

        for required in [
            "Open Writing Assistant",
            "Confirm a Prompt Mode",
            "Hold the configured Dictation shortcut",
            "Release to finalize",
            "Press Return only when ready",
            "A short press does nothing.",
            "does not run the Prompt Mode or insert text into another app",
        ] {
            XCTAssertTrue(english.contains(required), required)
        }
        for step in [
            "1. **Open Writing Assistant**",
            "2. **Confirm a Prompt Mode**",
            "3. **Put the caret in the source draft, or select text to replace.**",
            "4. **Hold the configured Dictation shortcut**",
            "5. **Release to finalize**",
            "6. Review and edit the dictated draft.",
            "7. **Press Return only when ready**",
            "Dictation inserts at the caret or replaces the selection.",
        ] {
            XCTAssertTrue(english.contains(step), step)
        }
        for required in [
            "打开写作助手",
            "确认一个 Prompt 模式",
            "长按已配置的听写快捷键",
            "松开以完成转写",
            "准备好后再按 Return",
            "短按不会执行任何操作",
            "不会运行 Prompt 模式，也不会把文本插入其他 App",
        ] {
            XCTAssertTrue(chinese.contains(required), required)
        }
        for step in [
            "1. 用 `Option+Space` **打开写作助手**",
            "2. **确认一个 Prompt 模式**",
            "3. **把光标放入原文草稿，或选中要替换的文本。**",
            "4. **长按已配置的听写快捷键**",
            "5. **松开以完成转写**",
            "6. 检查并编辑听写草稿。",
            "7. **准备好后再按 Return**",
            "听写会在光标处插入，或替换选区。",
        ] {
            XCTAssertTrue(chinese.contains(step), step)
        }
        for retired in [
            "Voice Write Assistant",
            "tap-to-toggle",
            "double-tap recording",
            "Voice Recording Mode",
            "compact voice window",
            "Auto Process",
            "单击开始/停止",
            "双击开始/停止",
        ] {
            XCTAssertFalse(combined.contains(retired), retired)
        }
    }

    func testSecurityAndManualChecklistCoverRealtimeDictationRisksAndWorkflowMatrix() throws {
        let security = try text(at: "SECURITY.md")
        for required in [
            "Realtime transport authentication",
            "bounded in-memory PCM",
            "terminal-session arbitration",
            "temporary recovery-file deletion",
            "audio payloads, transcript contents, Authorization headers, microphone identifiers, or temporary file paths",
        ] {
            XCTAssertTrue(security.contains(required), required)
        }

        let checklist = try text(at: "docs/manual-test-checklist.md")
        for required in [
            "mode picker and result editor",
            "modifier already held",
            "combining marks",
            "one-step undo",
            "marked-text Escape",
            "connection failure while held",
            "late-event races",
            "permission is not requested",
            "rapid reopen",
            "no draft-only History",
            "legacy Voice History",
            "phase-only announcements",
        ] {
            XCTAssertTrue(checklist.contains(required), required)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private func propertyList(at fileURL: URL) throws -> [String: Any] {
        try propertyList(from: Data(contentsOf: fileURL))
    }

    private func propertyList(from data: Data) throws -> [String: Any] {
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(propertyList as? [String: Any])
    }

    private func text(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func isTruePlistBoolean(_ value: Any?) -> Bool {
        guard let value,
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
        else {
            return false
        }
        return (value as? Bool) == true
    }
}
