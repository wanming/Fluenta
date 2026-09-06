import Foundation
import XCTest

final class WritingDictationLocalizationTests: XCTestCase {
    private let approvedTableIDs = [
        "en", "zhHans", "zhHant", "ja", "ko",
        "es", "fr", "de", "pt", "it",
    ]

    private let dictationKeys: Set<String> = [
        "settings.group.writing",
        "settings.group.writing.help",
        "settings.group.dictation",
        "settings.group.dictation.help",
        "settings.group.dictationAdvanced",
        "settings.row.dictationShortcut",
        "settings.help.dictationShortcut",
        "settings.row.microphone",
        "settings.help.microphone",
        "settings.row.fallbackSpeechEndpoint",
        "settings.help.fallbackSpeechEndpoint",
        "settings.row.fallbackSpeechModel",
        "settings.help.fallbackSpeechModel",
        "settings.error.invalidFallbackSpeechEndpoint",
        "dictation.hint.hold",
        "dictation.status.connecting",
        "dictation.status.listening",
        "dictation.status.recordingFallback",
        "dictation.status.finalizing",
        "dictation.status.recovering",
        "dictation.status.ready",
        "dictation.accessibility.ready",
        "dictation.accessibility.listening",
        "dictation.accessibility.recordingFallback",
        "dictation.accessibility.finalizing",
        "dictation.accessibility.recovering",
        "dictation.accessibility.completed",
        "dictation.accessibility.cancelled",
        "dictation.accessibility.failed",
        "dictation.accessibility.sourceEditor",
        "dictation.undo.action",
        "dictation.error.missingAPIKey",
        "dictation.error.microphonePermission",
        "dictation.error.noAudioInputDevice",
        "dictation.error.recordingUnavailable",
        "dictation.error.realtimeBufferOverflow",
        "dictation.error.connection",
        "dictation.error.connectionTimeout",
        "dictation.error.finalTimeout",
        "dictation.error.fallback",
        "dictation.error.noSpeech",
    ]

    private let retiredKeysAndSymbols = [
        "settings.section.voiceWriteAssistant",
        "settings.description.voice",
        "settings.row.voiceShortcut",
        "settings.help.voiceShortcut",
        "settings.row.voiceRecordingMode",
        "settings.help.voiceRecordingMode",
        "settings.voiceRecordingMode.tapToToggle",
        "settings.voiceRecordingMode.pressAndHold",
        "settings.voiceRecordingMode.doubleTap",
        "settings.voiceRecordingMode.holdKey",
        "settings.quickStart.voice.tapToToggle",
        "settings.quickStart.voice.doubleTap",
        "settings.row.speechProfile",
        "settings.help.speechProfile",
        "settings.speech.profile.openAIBalanced",
        "settings.speech.profile.openAIAccuracy",
        "settings.speech.profile.openAIWhisper",
        "settings.speech.profile.custom",
        "settings.row.speechEndpoint",
        "settings.help.speechEndpoint",
        "settings.row.speechModel",
        "settings.help.speechModel",
        "settings.row.voiceAutoProcess",
        "settings.help.voiceAutoProcess",
        "settings.row.voicePostTranscriptionAction",
        "settings.help.voicePostTranscriptionAction",
        "settings.voicePostTranscription.useDefaultPromptMode",
        "settings.voicePostTranscription.askEachTime",
        "settings.voicePostTranscription.insertRawTranscript",
        "settings.row.voiceCleanupMode",
        "settings.help.voiceCleanupMode",
        "voice.status.listening",
        "voice.status.transcribing",
        "voice.status.choosingPromptMode",
        "voice.status.polishing",
        "voice.status.inserting",
        "voice.promptMode.title",
        "voice.promptMode.default",
        "voice.promptMode.rawTranscript",
        "voice.error.microphonePermission",
        "voice.error.noAudioInputDevice",
        "voice.error.recordingUnavailable",
        "voice.error.invalidSpeechEndpoint",
        "voice.error.missingSpeechAPIKey",
        "popover.hint.voice",
        "VoiceInputConfig.RecordingMode",
        "VoiceInputConfig.SpeechProfile",
        "VoiceInputConfig.PostTranscriptionAction",
    ]

    private let expectedEnglishValues = [
        "settings.group.writing": "Writing",
        "settings.group.dictation": "Dictation",
        "settings.group.dictationAdvanced": "Advanced Dictation",
        "settings.row.dictationShortcut": "Hold shortcut",
        "settings.row.fallbackSpeechEndpoint": "Recovery endpoint",
        "settings.row.fallbackSpeechModel": "Recovery model",
        "dictation.hint.hold": "Hold %@ to dictate",
        "dictation.status.connecting": "Connecting…",
        "dictation.status.listening": "Listening… Release to finish",
        "dictation.status.recordingFallback": "Connection lost… Keep speaking",
        "dictation.status.finalizing": "Finishing transcription…",
        "dictation.status.recovering": "Recovering from the temporary recording…",
        "dictation.status.ready": "Dictation ready",
        "dictation.error.noSpeech": "No speech was recognized.",
    ]

    private let expectedSimplifiedChineseValues = [
        "settings.group.writing": "写作",
        "settings.group.dictation": "听写",
        "settings.group.dictationAdvanced": "高级听写",
        "settings.row.dictationShortcut": "长按快捷键",
        "settings.row.fallbackSpeechEndpoint": "恢复转写端点",
        "settings.row.fallbackSpeechModel": "恢复转写模型",
        "dictation.hint.hold": "长按 %@ 开始听写",
        "dictation.status.connecting": "正在连接…",
        "dictation.status.listening": "正在听写…松开以完成",
        "dictation.status.recordingFallback": "连接已断开…可继续说话",
        "dictation.status.finalizing": "正在完成转写…",
        "dictation.status.recovering": "正在使用临时录音恢复…",
        "dictation.status.ready": "听写已就绪",
        "dictation.error.noSpeech": "未识别到语音。",
    ]

    func testEverySupportedTableContainsEveryDictationKeyExactlyOnce() throws {
        let source = try localizationSource()
        XCTAssertEqual(Set(try localizationTableIDs(in: source)), Set(approvedTableIDs))

        for tableID in approvedTableIDs {
            let tableSource = try localizationTableSource(tableID, in: source)
            for key in dictationKeys {
                XCTAssertEqual(
                    countDictionaryEntries(key, in: tableSource),
                    1,
                    "Expected exactly one \(key) entry in \(tableID)"
                )
                let entry = normalizedDictionaryEntries(in: tableSource).first {
                    $0.hasPrefix(#""\#(key)":"#)
                }
                XCTAssertNotNil(entry, "Missing \(key) in \(tableID)")
                XCTAssertNotEqual(entry, #""\#(key)": """#, "Empty \(key) in \(tableID)")
            }

            let holdEntry = try XCTUnwrap(
                normalizedDictionaryEntries(in: tableSource).first {
                    $0.hasPrefix(#""dictation.hint.hold":"#)
                }
            )
            XCTAssertEqual(
                holdEntry.components(separatedBy: "%@").count - 1,
                1,
                "Expected one shortcut placeholder in \(tableID)"
            )
        }
    }

    func testApprovedEnglishAndSimplifiedChineseDictationCopyMatchesTheDesign() throws {
        let source = try localizationSource()
        try assertValues(expectedEnglishValues, in: "en", source: source)
        try assertValues(expectedSimplifiedChineseValues, in: "zhHans", source: source)
    }

    func testRetiredStandaloneVoiceCopyAndLocalizedExtensionsAreAbsent() throws {
        let source = try localizationSource()
        for retired in retiredKeysAndSymbols {
            XCTAssertFalse(source.contains(retired), retired)
        }

        XCTAssertTrue(source.contains("extension VoiceInputConfig.Shortcut"))
        for tableID in approvedTableIDs {
            let tableSource = try localizationTableSource(tableID, in: source)
            XCTAssertEqual(countDictionaryEntries("settings.history.source.voice", in: tableSource), 1)
            XCTAssertEqual(countDictionaryEntries("settings.quickStart.voice.pressAndHold", in: tableSource), 1)
        }
    }

    func testDictationAccessibilityUndoAndErrorKeysAreWiredToProductionSurfaces() throws {
        let popover = try sourceFile("Sources/InkletApp/InkletPopoverView.swift")
        let transaction = try sourceFile("Sources/InkletApp/DictationEditorTransaction.swift")
        let controller = try sourceFile("Sources/InkletApp/InkletPopoverWindowController.swift")
        let recorder = try sourceFile("Sources/InkletApp/AudioRecorder.swift")
        let coordinator = try sourceFile("Sources/InkletApp/WritingDictationCoordinator.swift")

        XCTAssertTrue(popover.contains("dictation.accessibility.sourceEditor"))
        XCTAssertTrue(transaction.contains("dictation.undo.action"))
        for key in [
            "dictation.accessibility.finalizing",
            "dictation.accessibility.recovering",
            "dictation.accessibility.completed",
            "dictation.accessibility.cancelled",
            "dictation.accessibility.failed",
        ] {
            XCTAssertTrue(controller.contains(key), key)
        }
        XCTAssertFalse(recorder.contains("voice.error."))
        XCTAssertTrue(recorder.contains("dictation.error.noAudioInputDevice"))
        XCTAssertTrue(coordinator.contains("dictation.error.connectionTimeout"))
        XCTAssertTrue(coordinator.contains("dictation.error.finalTimeout"))
        XCTAssertFalse(coordinator.contains("dictation.error.editorUnavailable"))
    }

    private func assertValues(
        _ expectedValues: [String: String],
        in tableID: String,
        source: String
    ) throws {
        let entries = normalizedDictionaryEntries(
            in: try localizationTableSource(tableID, in: source)
        )
        for (key, value) in expectedValues {
            XCTAssertTrue(
                entries.contains(#""\#(key)": "\#(value)""#),
                "Unexpected \(key) in \(tableID)"
            )
        }
    }

    private func localizationSource() throws -> String {
        try sourceFile("Sources/InkletApp/InkletLocalization.swift")
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func localizationTableIDs(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(
            pattern: #"^[ \t]*private[ \t]+static[ \t]+let[ \t]+([A-Za-z_][A-Za-z0-9_]*):[ \t]*\[String:[ \t]*String\][ \t]*=[ \t]*\["#,
            options: .anchorsMatchLines
        )
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: sourceRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        }
    }

    private func localizationTableSource(_ tableID: String, in source: String) throws -> String {
        let declaration = "    private static let \(tableID): [String: String] = ["
        let declarationRange = try XCTUnwrap(
            source.range(of: declaration),
            "Missing localization table declaration for \(tableID)"
        )
        let tableStart = declarationRange.upperBound
        let tableEnd = try XCTUnwrap(
            source.range(of: "\n    ]", range: tableStart..<source.endIndex),
            "Missing localization table terminator for \(tableID)"
        )
        return String(source[tableStart..<tableEnd.lowerBound])
    }

    private func normalizedDictionaryEntries(in tableSource: String) -> [String] {
        tableSource.split(separator: "\n").map { line in
            let entry = line.trimmingCharacters(in: .whitespaces)
            return entry.hasSuffix(",") ? String(entry.dropLast()) : entry
        }
    }

    private func countDictionaryEntries(_ key: String, in source: String) -> Int {
        source.components(separatedBy: #""\#(key)":"#).count - 1
    }
}
