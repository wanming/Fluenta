import XCTest
@testable import InkletCore

final class SelectionActionsConfigTests: XCTestCase {
    func testDefaultConfigIsEnabledAndFollowsInterfaceLanguage() {
        let config = SelectionActionsConfig.defaultConfig()

        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.translationLanguage, .followInterfaceLanguage)
        XCTAssertEqual(config.pronunciationVoice, .alloy)
        XCTAssertEqual(config.pronunciationSpeed, 1.0)
        XCTAssertEqual(config.forceSelectionMode, .menuCopyThenShortcut)
    }

    func testForceSelectionModeCasesMatchEasyDictFallbackOrder() {
        XCTAssertEqual(SelectionForceSelectionMode.allCases, [
            .disabled,
            .menuCopyOnly,
            .menuCopyThenShortcut,
            .shortcutThenMenuCopy
        ])
    }

    func testPronunciationSpeedUsesCompactSettingsRange() {
        XCTAssertEqual(SelectionActionsConfig.minimumPronunciationSpeed, 0.75)
        XCTAssertEqual(SelectionActionsConfig.maximumPronunciationSpeed, 1.5)
        XCTAssertEqual(SelectionActionsConfig.defaultPronunciationSpeed, 1.0)
    }

    func testPronunciationSpeedIsClampedToSettingsRange() {
        XCTAssertEqual(
            SelectionActionsConfig(pronunciationSpeed: 0.25).pronunciationSpeed,
            SelectionActionsConfig.minimumPronunciationSpeed
        )
        XCTAssertEqual(
            SelectionActionsConfig(pronunciationSpeed: 4.0).pronunciationSpeed,
            SelectionActionsConfig.maximumPronunciationSpeed
        )
    }

    func testDefaultConfigIncludesDefaultTranslationPrompt() {
        let config = SelectionActionsConfig.defaultConfig()

        XCTAssertEqual(config.translationPrompt, SelectionActionsConfig.defaultTranslationPrompt)
        XCTAssertTrue(config.translationPrompt.contains("{targetLanguage}"))
        XCTAssertTrue(config.translationPrompt.contains("single word"))
        XCTAssertTrue(config.translationPrompt.contains("phonetic"))
        XCTAssertTrue(config.translationPrompt.contains("example sentence"))
    }

    func testTranslationLanguagePromptNames() {
        XCTAssertEqual(SelectionTranslationLanguage.english.promptTargetName, "English")
        XCTAssertEqual(SelectionTranslationLanguage.simplifiedChinese.promptTargetName, "Simplified Chinese")
        XCTAssertEqual(SelectionTranslationLanguage.traditionalChinese.promptTargetName, "Traditional Chinese")
        XCTAssertEqual(SelectionTranslationLanguage.japanese.promptTargetName, "Japanese")
        XCTAssertEqual(SelectionTranslationLanguage.korean.promptTargetName, "Korean")
        XCTAssertEqual(SelectionTranslationLanguage.spanish.promptTargetName, "Spanish")
        XCTAssertEqual(SelectionTranslationLanguage.french.promptTargetName, "French")
        XCTAssertEqual(SelectionTranslationLanguage.german.promptTargetName, "German")
        XCTAssertEqual(SelectionTranslationLanguage.portuguese.promptTargetName, "Portuguese")
        XCTAssertEqual(SelectionTranslationLanguage.italian.promptTargetName, "Italian")
    }

    func testPronunciationVoicesUseOpenAIVoiceIDs() {
        XCTAssertEqual(SelectionPronunciationVoice.allCases.map(\.rawValue), [
            "alloy",
            "ash",
            "ballad",
            "coral",
            "echo",
            "fable",
            "nova",
            "onyx",
            "sage",
            "shimmer",
            "verse",
            "marin",
            "cedar"
        ])
    }

    func testPronunciationPreviewTextResolvesInterfaceLanguage() {
        XCTAssertEqual(SelectionPronunciationVoice.previewText(interfaceLanguageCode: "zh-Hans"), "这是 Inklet。")
        XCTAssertEqual(SelectionPronunciationVoice.previewText(interfaceLanguageCode: "zh-Hant"), "這是 Inklet。")
        XCTAssertEqual(SelectionPronunciationVoice.previewText(interfaceLanguageCode: "ja"), "Inklet です。")
        XCTAssertEqual(SelectionPronunciationVoice.previewText(interfaceLanguageCode: "ko"), "Inklet입니다.")
        XCTAssertEqual(SelectionPronunciationVoice.previewText(interfaceLanguageCode: "unknown"), "This is Inklet.")
    }

    func testDecodingOldConfigDefaultsPronunciationVoice() throws {
        let data = #"{"isEnabled":false,"translationLanguage":"japanese"}"#.data(using: .utf8)!

        let config = try JSONDecoder().decode(SelectionActionsConfig.self, from: data)

        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.translationLanguage, .japanese)
        XCTAssertEqual(config.pronunciationVoice, .alloy)
        XCTAssertEqual(config.pronunciationSpeed, 1.0)
        XCTAssertEqual(config.forceSelectionMode, .menuCopyThenShortcut)
    }

    func testForceSelectionModeRoundTripsThroughCodable() throws {
        let config = SelectionActionsConfig(forceSelectionMode: .menuCopyOnly)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SelectionActionsConfig.self, from: data)

        XCTAssertEqual(decoded.forceSelectionMode, .menuCopyOnly)
    }

    func testDecodingClampsPronunciationSpeed() throws {
        let slowData = #"{"pronunciationSpeed":0.25}"#.data(using: .utf8)!
        let fastData = #"{"pronunciationSpeed":4.0}"#.data(using: .utf8)!

        let slowConfig = try JSONDecoder().decode(SelectionActionsConfig.self, from: slowData)
        let fastConfig = try JSONDecoder().decode(SelectionActionsConfig.self, from: fastData)

        XCTAssertEqual(slowConfig.pronunciationSpeed, SelectionActionsConfig.minimumPronunciationSpeed)
        XCTAssertEqual(fastConfig.pronunciationSpeed, SelectionActionsConfig.maximumPronunciationSpeed)
    }

    func testDecodingOldConfigDefaultsTranslationPrompt() throws {
        let data = #"{"isEnabled":false,"translationLanguage":"japanese","pronunciationVoice":"cedar"}"#.data(using: .utf8)!

        let config = try JSONDecoder().decode(SelectionActionsConfig.self, from: data)

        XCTAssertEqual(config.translationPrompt, SelectionActionsConfig.defaultTranslationPrompt)
    }

    func testDecodingLegacyDefaultTranslationPromptMigratesToCurrentDefault() throws {
        let legacyPrompt = """
        Translate the user's selected text into {targetLanguage}.
        Preserve the original meaning, names, numbers, formatting, and tone.
        Do not add explanations, alternatives, quotes, markdown, or commentary.
        Return only the translated text.
        """
        let data = try JSONEncoder().encode(["translationPrompt": legacyPrompt])

        let config = try JSONDecoder().decode(SelectionActionsConfig.self, from: data)

        XCTAssertEqual(config.translationPrompt, SelectionActionsConfig.defaultTranslationPrompt)
        XCTAssertNotEqual(config.translationPrompt, legacyPrompt)
    }

    func testDecodingCustomTranslationPromptPreservesCustomization() throws {
        let customPrompt = "Explain {targetLanguage} nuance in one paragraph."
        let data = try JSONEncoder().encode(["translationPrompt": customPrompt])

        let config = try JSONDecoder().decode(SelectionActionsConfig.self, from: data)

        XCTAssertEqual(config.translationPrompt, customPrompt)
    }

    func testEffectiveTranslationPromptReplacesTargetLanguage() {
        let config = SelectionActionsConfig(
            translationPrompt: "Rewrite into {targetLanguage}. Return only text."
        )

        XCTAssertEqual(
            config.effectiveTranslationPrompt(targetLanguageName: "Japanese"),
            "Rewrite into Japanese. Return only text."
        )
    }

    func testEffectiveTranslationPromptFallsBackWhenBlank() {
        let config = SelectionActionsConfig(translationPrompt: "  \n  ")

        let prompt = config.effectiveTranslationPrompt(targetLanguageName: "German")

        XCTAssertTrue(prompt.contains("German"))
        XCTAssertTrue(prompt.contains("single word"))
        XCTAssertTrue(prompt.contains("phonetic pronunciation"))
    }

    func testFollowInterfaceLanguageResolvesSupportedLanguages() {
        XCTAssertEqual(
            SelectionTranslationLanguage.followInterfaceLanguage.resolvedPromptTargetName(interfaceLanguageCode: "zh-Hans"),
            "Simplified Chinese"
        )
        XCTAssertEqual(
            SelectionTranslationLanguage.followInterfaceLanguage.resolvedPromptTargetName(interfaceLanguageCode: "zh-Hant"),
            "Traditional Chinese"
        )
        XCTAssertEqual(
            SelectionTranslationLanguage.followInterfaceLanguage.resolvedPromptTargetName(interfaceLanguageCode: "ja"),
            "Japanese"
        )
        XCTAssertEqual(
            SelectionTranslationLanguage.followInterfaceLanguage.resolvedPromptTargetName(interfaceLanguageCode: "ko"),
            "Korean"
        )
        XCTAssertEqual(
            SelectionTranslationLanguage.followInterfaceLanguage.resolvedPromptTargetName(interfaceLanguageCode: "es"),
            "Spanish"
        )
        XCTAssertEqual(
            SelectionTranslationLanguage.followInterfaceLanguage.resolvedPromptTargetName(interfaceLanguageCode: "fr"),
            "French"
        )
        XCTAssertEqual(
            SelectionTranslationLanguage.followInterfaceLanguage.resolvedPromptTargetName(interfaceLanguageCode: "de"),
            "German"
        )
        XCTAssertEqual(
            SelectionTranslationLanguage.followInterfaceLanguage.resolvedPromptTargetName(interfaceLanguageCode: "pt"),
            "Portuguese"
        )
        XCTAssertEqual(
            SelectionTranslationLanguage.followInterfaceLanguage.resolvedPromptTargetName(interfaceLanguageCode: "it"),
            "Italian"
        )
    }

    func testFollowInterfaceLanguageFallsBackToEnglish() {
        XCTAssertEqual(
            SelectionTranslationLanguage.followInterfaceLanguage.resolvedPromptTargetName(interfaceLanguageCode: "unknown"),
            "English"
        )
    }
}
