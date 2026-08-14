import Foundation

public enum AppAppearance: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var providerID: String
    public var model: String
    public var timeoutSeconds: Double
    public var hotkey: String
    public var appearance: AppAppearance
    public var promptModes: [PromptMode]
    public var customOpenAICompatibleEndpoint: String
    public var voiceInput: VoiceInputConfig
    public var selectionActions: SelectionActionsConfig

    public init(
        version: Int = AppConfig.currentVersion,
        providerID: String = LLMProviderPreset.openAI.id,
        model: String,
        timeoutSeconds: Double,
        hotkey: String,
        appearance: AppAppearance = .system,
        promptModes: [PromptMode],
        customOpenAICompatibleEndpoint: String = LLMProviderPreset.customOpenAICompatible.endpoint.absoluteString,
        voiceInput: VoiceInputConfig = VoiceInputConfig.defaultConfig(),
        selectionActions: SelectionActionsConfig = SelectionActionsConfig.defaultConfig()
    ) {
        self.version = version
        self.providerID = providerID
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.hotkey = hotkey
        self.appearance = appearance
        self.promptModes = promptModes
        self.customOpenAICompatibleEndpoint = customOpenAICompatibleEndpoint
        self.voiceInput = voiceInput
        self.selectionActions = selectionActions
    }

    public static func defaultConfig() -> AppConfig {
        AppConfig(
            providerID: LLMProviderPreset.openAI.id,
            model: LLMProviderPreset.openAI.defaultModel,
            timeoutSeconds: 20,
            hotkey: "⌥Space",
            appearance: .system,
            promptModes: PromptModeStore.defaultStore().modes
        )
    }

    public var resolvedProviderPreset: LLMProviderPreset {
        LLMProviderPreset.openAI
    }

    public var promptModeStore: PromptModeStore {
        PromptModeStore(modes: promptModes)
    }

    public var visiblePromptModes: [PromptMode] {
        promptModeStore.visibleModes
    }

    public var defaultVisibleModeID: String {
        visiblePromptModes.first?.id ?? PromptMode.translateToEnglishID
    }

    public func visibleModeID(preferredModeID: String) -> String {
        let visibleModeIDs = Set(visiblePromptModes.map(\.id))
        if visibleModeIDs.contains(preferredModeID) {
            return preferredModeID
        }

        return defaultVisibleModeID
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case providerID
        case model
        case timeoutSeconds
        case hotkey
        case appearance
        case promptModes
        case customOpenAICompatibleEndpoint
        case voiceInput
        case selectionActions
    }

    public init(from decoder: Decoder) throws {
        let defaults = AppConfig.defaultConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        version = max(decodedVersion, AppConfig.currentVersion)
        let decodedProviderID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? defaults.providerID
        providerID = LLMProviderPreset.openAI.id
        if decodedProviderID == LLMProviderPreset.openAI.id {
            model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        } else {
            model = defaults.model
        }
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
        hotkey = try container.decodeIfPresent(String.self, forKey: .hotkey) ?? defaults.hotkey
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? defaults.appearance
        promptModes = AppConfig.migratedPromptModes(
            try container.decodeIfPresent([PromptMode].self, forKey: .promptModes) ?? defaults.promptModes
        )
        customOpenAICompatibleEndpoint = try container.decodeIfPresent(
            String.self,
            forKey: .customOpenAICompatibleEndpoint
        ) ?? defaults.customOpenAICompatibleEndpoint
        voiceInput = AppConfig.migratedVoiceInput(
            try container.decodeIfPresent(VoiceInputConfig.self, forKey: .voiceInput) ?? defaults.voiceInput,
            fromVersion: decodedVersion
        )
        selectionActions = try container.decodeIfPresent(
            SelectionActionsConfig.self,
            forKey: .selectionActions
        ) ?? defaults.selectionActions
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(version, forKey: .version)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(model, forKey: .model)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(promptModes, forKey: .promptModes)
        try container.encode(customOpenAICompatibleEndpoint, forKey: .customOpenAICompatibleEndpoint)
        try container.encode(voiceInput, forKey: .voiceInput)
        try container.encode(selectionActions, forKey: .selectionActions)
    }

    private static func migratedPromptModes(_ modes: [PromptMode]) -> [PromptMode] {
        let defaultModes = PromptModeStore.defaultStore().modes
        let defaultIDs = Set(defaultModes.map(\.id))
        let retiredIDs = retiredBuiltInPromptModeIDs
        let shouldMigrateBuiltIns = modes.contains { retiredIDs.contains($0.id) }
            || modes.contains { $0.id == PromptMode.translateToEnglishID && $0.name != defaultModes[0].name }
        let hasCurrentBuiltIns = modes.contains { defaultIDs.contains($0.id) }

        guard shouldMigrateBuiltIns || hasCurrentBuiltIns else {
            return modes
        }

        let migratedModes: [PromptMode]
        if shouldMigrateBuiltIns {
            let customModes = modes.filter { mode in
                !retiredIDs.contains(mode.id) && !defaultIDs.contains(mode.id)
            }
            migratedModes = defaultModes + customModes
        } else {
            let existingIDs = Set(modes.map(\.id))
            let missingDefaultModes = hasCurrentBuiltIns ? defaultModes.filter { !existingIDs.contains($0.id) } : []
            migratedModes = modes + missingDefaultModes
        }

        return migratedModes
            .enumerated()
            .map { index, mode in
                var migratedMode = mode
                if migratedMode.id == PromptMode.voiceCleanupID,
                   migratedMode.systemPrompt == legacyVoiceCleanupSystemPrompt,
                   let defaultVoiceCleanupMode = defaultModes.first(where: { $0.id == PromptMode.voiceCleanupID }) {
                    migratedMode.systemPrompt = defaultVoiceCleanupMode.systemPrompt
                }
                migratedMode.participatesInAuto = false
                migratedMode.autoRule = .none
                migratedMode.sortOrder = index
                return migratedMode
            }
    }

    private static func migratedVoiceInput(
        _ voiceInput: VoiceInputConfig,
        fromVersion version: Int
    ) -> VoiceInputConfig {
        guard version < 2, voiceInput.recordingMode == .tapToToggle else {
            return voiceInput
        }

        var migratedVoiceInput = voiceInput
        migratedVoiceInput.recordingMode = .pressAndHold
        return migratedVoiceInput
    }

    private static var legacyVoiceCleanupSystemPrompt: String {
        """
        Rewrite raw speech transcription into text that is ready to insert.
        Preserve the user's intended meaning, language, names, numbers, code terms, and domain terms.
        Do not translate.
        Remove filler words, hesitation sounds, throat-clearing phrases, rambling setup, repeated words, repeated sentences, false starts, and abandoned fragments.
        When the user corrects themselves or gives multiple versions, keep the final intended version.
        Make the result concise, natural, and coherent, but do not add facts, examples, or intent that was not spoken.
        Keep useful details even if the original speech was messy.
        Fix punctuation, capitalization, and minor grammar issues.
        If there is no meaningful content, return an empty string.
        Return only the final cleaned text.
        """
    }

    private static var retiredBuiltInPromptModeIDs: Set<String> {
        [
            PromptMode.autoID,
            PromptMode.chineseToEnglishID,
            PromptMode.polishEnglishID,
            PromptMode.improveWritingID,
            PromptMode.makeConciseID,
            PromptMode.professionalToneID,
            PromptMode.friendlyReplyID,
            PromptMode.customPromptID
        ]
    }
}

public enum ConfigStoreError: Error, Equatable {
    case encodingFailed
    case decodingFailed
}

public protocol ConfigStore {
    func load() throws -> AppConfig
    func save(_ config: AppConfig) throws
}

public struct UserDefaultsConfigStore: ConfigStore {
    public static let defaultKey = "appConfig"

    private let userDefaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = UserDefaultsConfigStore.defaultKey,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.encoder = encoder
        self.decoder = decoder
    }

    public func load() throws -> AppConfig {
        guard let data = userDefaults.data(forKey: key) else {
            return AppConfig.defaultConfig()
        }

        do {
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            throw ConfigStoreError.decodingFailed
        }
    }

    public func save(_ config: AppConfig) throws {
        do {
            let data = try encoder.encode(config)
            userDefaults.set(data, forKey: key)
        } catch {
            throw ConfigStoreError.encodingFailed
        }
    }
}

public struct LocalAPIKeyStore: @unchecked Sendable {
    public static let defaultKeyPrefix = "providerAPIKey"
    public static let defaultKeychainService = "Inklet.ProviderAPIKey"
    public static let localBundleIdentifier = "com.tomwan.inklet.local"
    public static let localKeychainService = "Inklet.Local.ProviderAPIKey"

    private let userDefaults: UserDefaults
    private let keyPrefix: String
    private let keychainStore: (String) -> KeychainStore

    public init(
        userDefaults: UserDefaults = .standard,
        keyPrefix: String = LocalAPIKeyStore.defaultKeyPrefix,
        keychainStore: @escaping (String) -> KeychainStore = { providerID in
            KeychainStore(service: LocalAPIKeyStore.resolvedKeychainService(), account: providerID)
        }
    ) {
        self.userDefaults = userDefaults
        self.keyPrefix = keyPrefix
        self.keychainStore = keychainStore
    }

    public static func resolvedKeychainService(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        bundleIdentifier == localBundleIdentifier ? localKeychainService : defaultKeychainService
    }

    public func loadAPIKey(forProviderID providerID: String) -> String? {
        let store = keychainStore(providerID)
        if let apiKey = try? store.loadAPIKey() {
            return apiKey
        }

        guard let legacyAPIKey = userDefaults.string(forKey: key(forProviderID: providerID)) else {
            return nil
        }

        do {
            try store.saveAPIKey(legacyAPIKey)
            userDefaults.removeObject(forKey: key(forProviderID: providerID))
        } catch {
            return legacyAPIKey
        }
        return legacyAPIKey
    }

    public func saveAPIKey(_ apiKey: String, forProviderID providerID: String) throws {
        try keychainStore(providerID).saveAPIKey(apiKey)
        userDefaults.removeObject(forKey: key(forProviderID: providerID))
    }

    public func deleteAPIKey(forProviderID providerID: String) throws {
        try keychainStore(providerID).deleteAPIKey()
        userDefaults.removeObject(forKey: key(forProviderID: providerID))
    }

    private func key(forProviderID providerID: String) -> String {
        "\(keyPrefix).\(providerID)"
    }
}
