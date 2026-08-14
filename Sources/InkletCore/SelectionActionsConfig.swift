import Foundation

public enum SelectionForceSelectionMode: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case disabled
    case menuCopyOnly
    case menuCopyThenShortcut
    case shortcutThenMenuCopy

    public static let settingsCases: [Self] = [.disabled, .menuCopyOnly]

    public var id: String { rawValue }

    var normalizedForSafeSettings: Self {
        self == .disabled ? .disabled : .menuCopyOnly
    }
}

public struct SelectionActionsConfig: Codable, Equatable, Sendable {
    public static let minimumPronunciationSpeed = 0.75
    public static let maximumPronunciationSpeed = 1.5
    public static let defaultPronunciationSpeed = 1.0

    public var isEnabled: Bool
    public var translationLanguage: SelectionTranslationLanguage
    public var pronunciationVoice: SelectionPronunciationVoice
    public var translationPrompt: String
    public var pronunciationSpeed: Double
    public var forceSelectionMode: SelectionForceSelectionMode
    public var allowsSimulatedCopyFallback: Bool

    static let legacyDefaultTranslationPrompt = """
    Translate the user's selected text into {targetLanguage}.
    Preserve the original meaning, names, numbers, formatting, and tone.
    Do not add explanations, alternatives, quotes, markdown, or commentary.
    Return only the translated text.
    """

    public static let defaultTranslationPrompt = """
    If the user's selected text is a single word, return a compact dictionary entry in {targetLanguage}.
    Include the word, phonetic pronunciation, concise translation, one natural example sentence, and the example sentence translation.
    If the word has multiple common meanings, include only the most useful meanings for the selected context when context is available.

    If the selected text is not a single word, translate it into {targetLanguage}.
    Preserve the original meaning, names, numbers, formatting, and tone.
    Do not add explanations, alternatives, quotes, markdown, or commentary beyond the dictionary entry fields for a single word.
    """

    public init(
        isEnabled: Bool = true,
        translationLanguage: SelectionTranslationLanguage = .followInterfaceLanguage,
        pronunciationVoice: SelectionPronunciationVoice = .alloy,
        translationPrompt: String = Self.defaultTranslationPrompt,
        pronunciationSpeed: Double = Self.defaultPronunciationSpeed,
        forceSelectionMode: SelectionForceSelectionMode = .menuCopyOnly,
        allowsSimulatedCopyFallback: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.translationLanguage = translationLanguage
        self.pronunciationVoice = pronunciationVoice
        self.translationPrompt = translationPrompt
        self.pronunciationSpeed = Self.clampedPronunciationSpeed(pronunciationSpeed)
        self.forceSelectionMode = forceSelectionMode.normalizedForSafeSettings
        self.allowsSimulatedCopyFallback = allowsSimulatedCopyFallback
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case translationLanguage
        case pronunciationVoice
        case translationPrompt
        case pronunciationSpeed
        case forceSelectionMode
        case allowsSimulatedCopyFallback
    }

    public init(from decoder: Decoder) throws {
        let defaults = Self.defaultConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        translationLanguage = try container.decodeIfPresent(
            SelectionTranslationLanguage.self,
            forKey: .translationLanguage
        ) ?? defaults.translationLanguage
        pronunciationVoice = try container.decodeIfPresent(
            SelectionPronunciationVoice.self,
            forKey: .pronunciationVoice
        ) ?? defaults.pronunciationVoice
        let decodedTranslationPrompt = try container.decodeIfPresent(String.self, forKey: .translationPrompt)
            ?? defaults.translationPrompt
        translationPrompt = decodedTranslationPrompt == Self.legacyDefaultTranslationPrompt
            ? defaults.translationPrompt
            : decodedTranslationPrompt
        pronunciationSpeed = Self.clampedPronunciationSpeed(
            try container.decodeIfPresent(Double.self, forKey: .pronunciationSpeed) ?? defaults.pronunciationSpeed
        )
        let decodedForceSelectionMode = try container.decodeIfPresent(
            SelectionForceSelectionMode.self,
            forKey: .forceSelectionMode
        ) ?? defaults.forceSelectionMode
        forceSelectionMode = decodedForceSelectionMode.normalizedForSafeSettings
        allowsSimulatedCopyFallback = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsSimulatedCopyFallback
        ) ?? false
    }

    public static func defaultConfig() -> SelectionActionsConfig {
        SelectionActionsConfig()
    }

    public func effectiveTranslationPrompt(targetLanguageName: String) -> String {
        let template = translationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultTranslationPrompt
            : translationPrompt
        return template.replacingOccurrences(of: "{targetLanguage}", with: targetLanguageName)
    }

    public static func clampedPronunciationSpeed(_ speed: Double) -> Double {
        min(max(speed, minimumPronunciationSpeed), maximumPronunciationSpeed)
    }
}

public enum SelectionPronunciationVoice: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case alloy
    case ash
    case ballad
    case coral
    case echo
    case fable
    case nova
    case onyx
    case sage
    case shimmer
    case verse
    case marin
    case cedar

    public var id: String { rawValue }

    public var displayName: String {
        rawValue.capitalized
    }

    public static func previewText(interfaceLanguageCode: String) -> String {
        let normalized = interfaceLanguageCode.lowercased()
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") {
            return "這是 Inklet。"
        }
        if normalized.hasPrefix("zh") { return "这是 Inklet。" }
        if normalized.hasPrefix("ja") { return "Inklet です。" }
        if normalized.hasPrefix("ko") { return "Inklet입니다." }
        if normalized.hasPrefix("es") { return "Esto es Inklet." }
        if normalized.hasPrefix("fr") { return "Voici Inklet." }
        if normalized.hasPrefix("de") { return "Das ist Inklet." }
        if normalized.hasPrefix("pt") { return "Este e o Inklet." }
        if normalized.hasPrefix("it") { return "Questo e Inklet." }
        return "This is Inklet."
    }
}

public enum SelectionTranslationLanguage: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case followInterfaceLanguage
    case english
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case korean
    case spanish
    case french
    case german
    case portuguese
    case italian

    public var id: String { rawValue }

    public var promptTargetName: String {
        switch self {
        case .followInterfaceLanguage:
            "English"
        case .english:
            "English"
        case .simplifiedChinese:
            "Simplified Chinese"
        case .traditionalChinese:
            "Traditional Chinese"
        case .japanese:
            "Japanese"
        case .korean:
            "Korean"
        case .spanish:
            "Spanish"
        case .french:
            "French"
        case .german:
            "German"
        case .portuguese:
            "Portuguese"
        case .italian:
            "Italian"
        }
    }

    public func resolvedPromptTargetName(interfaceLanguageCode: String) -> String {
        guard self == .followInterfaceLanguage else {
            return promptTargetName
        }

        let normalized = interfaceLanguageCode.lowercased()
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") {
            return SelectionTranslationLanguage.traditionalChinese.promptTargetName
        }
        if normalized.hasPrefix("zh") { return SelectionTranslationLanguage.simplifiedChinese.promptTargetName }
        if normalized.hasPrefix("ja") { return SelectionTranslationLanguage.japanese.promptTargetName }
        if normalized.hasPrefix("ko") { return SelectionTranslationLanguage.korean.promptTargetName }
        if normalized.hasPrefix("es") { return SelectionTranslationLanguage.spanish.promptTargetName }
        if normalized.hasPrefix("fr") { return SelectionTranslationLanguage.french.promptTargetName }
        if normalized.hasPrefix("de") { return SelectionTranslationLanguage.german.promptTargetName }
        if normalized.hasPrefix("pt") { return SelectionTranslationLanguage.portuguese.promptTargetName }
        if normalized.hasPrefix("it") { return SelectionTranslationLanguage.italian.promptTargetName }
        return SelectionTranslationLanguage.english.promptTargetName
    }
}
