import XCTest

final class VoiceSettingsLocalizationTests: XCTestCase {
    func testPostTranscriptionDefaultActionCopyMatchesCleanupModeLabel() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let localizationURL = packageRoot.appendingPathComponent("Sources/InkletApp/InkletLocalization.swift")
        let source = try String(contentsOf: localizationURL, encoding: .utf8)

        XCTAssertTrue(source.contains(#""settings.voicePostTranscription.useDefaultPromptMode": "Use Cleanup Mode""#))
        XCTAssertTrue(source.contains("uses the cleanup mode below"))
        XCTAssertFalse(source.contains("Use Default Mode"))
    }

    func testRecordingModeCopyExistsInAllLanguageTables() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let localizationURL = packageRoot.appendingPathComponent("Sources/InkletApp/InkletLocalization.swift")
        let source = try String(contentsOf: localizationURL, encoding: .utf8)

        XCTAssertTrue(source.contains(#""settings.row.voiceRecordingMode": "Recording Mode""#))
        XCTAssertTrue(source.contains(#""settings.voiceRecordingMode.pressAndHold": "Hold to record""#))
        XCTAssertTrue(source.contains(#""settings.voiceRecordingMode.doubleTap": "Double-tap to start/stop""#))
        XCTAssertTrue(source.contains(#""settings.row.voiceRecordingMode": "录音方式""#))
        XCTAssertTrue(source.contains(#""settings.voiceRecordingMode.pressAndHold": "按住录音""#))
        XCTAssertTrue(source.contains(#""settings.voiceRecordingMode.doubleTap": "双击开始/停止""#))
        XCTAssertEqual(countDictionaryEntries("settings.row.voiceRecordingMode", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.help.voiceRecordingMode", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.voiceRecordingMode.tapToToggle", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.voiceRecordingMode.pressAndHold", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.voiceRecordingMode.doubleTap", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.voiceRecordingMode.holdKey", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.quickStart.voice.tapToToggle", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.quickStart.voice.pressAndHold", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.quickStart.voice.doubleTap", in: source), 10)
    }

    func testForceSelectionModeCopyExistsInAllLanguageTables() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let localizationURL = packageRoot.appendingPathComponent("Sources/InkletApp/InkletLocalization.swift")
        let source = try String(contentsOf: localizationURL, encoding: .utf8)

        XCTAssertTrue(source.contains(#""settings.row.forceSelectionMode": "Force Selection""#))
        XCTAssertTrue(source.contains(#""settings.forceSelection.menuCopyThenShortcut": "Menu Copy, then Cmd+C""#))
        XCTAssertTrue(source.contains(#""settings.row.forceSelectionMode": "强制取词""#))
        XCTAssertTrue(source.contains(#""settings.forceSelection.menuCopyThenShortcut": "先菜单复制，再 Cmd+C""#))
        XCTAssertEqual(countDictionaryEntries("settings.row.forceSelectionMode", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.help.forceSelectionMode", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.forceSelection.disabled", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.forceSelection.menuCopyOnly", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.forceSelection.menuCopyThenShortcut", in: source), 10)
        XCTAssertEqual(countDictionaryEntries("settings.forceSelection.shortcutThenMenuCopy", in: source), 10)
    }

    private func countDictionaryEntries(_ key: String, in source: String) -> Int {
        source.components(separatedBy: #""\#(key)":"#).count - 1
    }
}
