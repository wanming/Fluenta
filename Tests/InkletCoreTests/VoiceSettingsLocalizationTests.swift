import XCTest

final class VoiceSettingsLocalizationTests: XCTestCase {
    func testHoldOnlyDictationKeepsCurrentShortcutAndLegacyHistoryLocalization() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let localizationURL = packageRoot.appendingPathComponent("Sources/InkletApp/InkletLocalization.swift")
        let source = try String(contentsOf: localizationURL, encoding: .utf8)

        XCTAssertEqual(countDictionaryEntries("settings.quickStart.voice.pressAndHold", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.history.source.voice", in: source), 10)
        XCTAssertTrue(source.contains("extension VoiceInputConfig.Shortcut"))
        XCTAssertFalse(source.contains("extension VoiceInputConfig.RecordingMode"))
        XCTAssertFalse(source.contains("extension VoiceInputConfig.SpeechProfile"))
        XCTAssertFalse(source.contains("extension VoiceInputConfig.PostTranscriptionAction"))
    }

    func testForceSelectionModeCopyExistsInAllLanguageTables() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let localizationURL = packageRoot.appendingPathComponent("Sources/InkletApp/InkletLocalization.swift")
        let source = try String(contentsOf: localizationURL, encoding: .utf8)

        XCTAssertTrue(source.contains(#""settings.row.forceSelectionMode": "Force Selection""#))
        XCTAssertTrue(source.contains(
            #""settings.help.forceSelectionMode": "Fallback used when Accessibility cannot read selected text. Menu Copy does not synthesize keyboard input.""#
        ))
        XCTAssertTrue(source.contains(#""settings.row.allowSimulatedCopyFallback": "Allow Simulated Cmd+C""#))
        XCTAssertTrue(source.contains(#""settings.forceSelection.menuCopyThenShortcut": "Menu Copy, then Cmd+C""#))
        XCTAssertTrue(source.contains(#""settings.row.forceSelectionMode": "强制取词""#))
        XCTAssertTrue(source.contains(
            #""settings.help.forceSelectionMode": "辅助功能无法读取选中文本时使用此备用方式。菜单复制不会模拟键盘输入。""#
        ))
        XCTAssertTrue(source.contains(#""settings.row.allowSimulatedCopyFallback": "允许模拟 Cmd+C""#))
        XCTAssertTrue(source.contains(#""settings.forceSelection.menuCopyThenShortcut": "先菜单复制，再 Cmd+C""#))
        XCTAssertEqual(countDictionaryEntries("settings.row.forceSelectionMode", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.help.forceSelectionMode", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.row.allowSimulatedCopyFallback", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.help.allowSimulatedCopyFallback", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.forceSelection.disabled", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.forceSelection.menuCopyOnly", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.forceSelection.menuCopyThenShortcut", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.forceSelection.shortcutThenMenuCopy", in: source), 10)
    }

    private func countDictionaryEntries(_ key: String, in source: String) -> Int {
        source.components(separatedBy: #""\#(key)":"#).count - 1
    }
}
