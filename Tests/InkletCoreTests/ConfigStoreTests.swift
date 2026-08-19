import XCTest
import Security
@testable import InkletCore

final class ConfigStoreTests: XCTestCase {
    private final class FakeKeychainClient: KeychainClient, @unchecked Sendable {
        enum Call: Equatable, Sendable {
            case copyMatching
            case update
            case add
            case delete
        }

        private struct State {
            var calls: [Call] = []
            var copyMatchingStatus: OSStatus = errSecItemNotFound
            var updateStatus: OSStatus = errSecItemNotFound
            var addStatus: OSStatus = errSecSuccess
            var deleteStatus: OSStatus = errSecSuccess
            var copyMatchingResult: Data?
        }

        private let lock = NSLock()
        private var state = State()

        var calls: [Call] {
            withState { $0.calls }
        }

        var copyMatchingStatus: OSStatus {
            get { withState { $0.copyMatchingStatus } }
            set { withState { $0.copyMatchingStatus = newValue } }
        }

        var updateStatus: OSStatus {
            get { withState { $0.updateStatus } }
            set { withState { $0.updateStatus = newValue } }
        }

        var addStatus: OSStatus {
            get { withState { $0.addStatus } }
            set { withState { $0.addStatus = newValue } }
        }

        var deleteStatus: OSStatus {
            get { withState { $0.deleteStatus } }
            set { withState { $0.deleteStatus = newValue } }
        }

        var copyMatchingResult: Data? {
            get { withState { $0.copyMatchingResult } }
            set { withState { $0.copyMatchingResult = newValue } }
        }

        func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            withState { state in
                state.calls.append(.copyMatching)
                result?.pointee = state.copyMatchingResult as CFData?
                return state.copyMatchingStatus
            }
        }

        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            withState { state in
                state.calls.append(.update)
                return state.updateStatus
            }
        }

        func add(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            withState { state in
                state.calls.append(.add)
                return state.addStatus
            }
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            withState { state in
                state.calls.append(.delete)
                return state.deleteStatus
            }
        }

        private func withState<T>(_ body: (inout State) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(&state)
        }
    }

    private func jsonString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func mode(id: String, sortOrder: Int, isVisible: Bool = true) -> PromptMode {
        PromptMode(
            id: id,
            name: id,
            description: "\(id) description",
            systemPrompt: "\(id) prompt",
            shortcut: nil,
            participatesInAuto: false,
            autoRule: .none,
            sortOrder: sortOrder,
            isVisible: isVisible
        )
    }

    func testRecognizedLegacyPreferenceKeysMatchRegistry() {
        XCTAssertEqual(InkletPreferenceKeys.recognizedLegacyKeys, [
            "appConfig",
            "modelCatalogSnapshot",
            "InkletInterfaceLanguage",
            "didCompleteOnboarding",
            "SelectionActionWindowController.translationPanelSize",
            "lastWritingPromptModeID"
        ])
    }

    func testProviderIDFromLegacyPreferenceKeyRequiresExactPrefixAndNonemptySuffix() {
        XCTAssertEqual(
            InkletPreferenceKeys.providerID(fromLegacyKey: "providerAPIKey.openai"),
            "openai"
        )
        XCTAssertEqual(
            InkletPreferenceKeys.providerID(fromLegacyKey: "providerAPIKey.openai.compatible"),
            "openai.compatible"
        )
        XCTAssertNil(InkletPreferenceKeys.providerID(fromLegacyKey: "providerAPIKey."))
        XCTAssertNil(InkletPreferenceKeys.providerID(fromLegacyKey: "other.openai"))
    }

    func testDefaultConfigMatchesSpec() {
        let config = AppConfig.defaultConfig()

        XCTAssertEqual(config.providerID, LLMProviderPreset.openAI.id)
        XCTAssertEqual(config.model, "gpt-5.6-luna")
        XCTAssertEqual(config.model, LLMProviderPreset.openAI.defaultModel)
        XCTAssertEqual(config.timeoutSeconds, 20)
        XCTAssertEqual(config.hotkey, "⌥Space")
        XCTAssertEqual(config.appearance, .system)
        XCTAssertEqual(config.defaultVisibleModeID, PromptMode.translateToEnglishID)
        XCTAssertEqual(
            config.customOpenAICompatibleEndpoint,
            LLMProviderPreset.customOpenAICompatible.endpoint.absoluteString
        )
        XCTAssertEqual(config.selectionActions, SelectionActionsConfig.defaultConfig())
    }

    func testConfigRoundTripsThroughUserDefaults() throws {
        let suiteName = "ConfigStoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsConfigStore(userDefaults: userDefaults)
        var config = AppConfig.defaultConfig()
        config.providerID = LLMProviderPreset.openAI.id
        config.model = "test-model"
        config.timeoutSeconds = 9
        config.hotkey = "⌘Space"
        config.appearance = .dark
        config.customOpenAICompatibleEndpoint = "http://127.0.0.1:1234/v1/chat/completions"
        config.selectionActions = SelectionActionsConfig(
            isEnabled: false,
            translationLanguage: .japanese,
            pronunciationVoice: .cedar,
            translationPrompt: "Translate into {targetLanguage} with short wording.",
            allowsSimulatedCopyFallback: true
        )
        config.promptModes = [
            PromptMode(
                id: "custom-test-mode",
                name: "Custom Test Mode",
                description: "Custom test description",
                systemPrompt: "Custom test prompt",
                shortcut: "⌘9",
                participatesInAuto: true,
                autoRule: .englishHeavy,
                sortOrder: 99,
                isVisible: false
            )
        ]

        try store.save(config)
        let loadedConfig = try store.load()

        XCTAssertEqual(loadedConfig, config)
    }

    func testConfigDecodeFallsBackToDefaultsForMissingFields() throws {
        let data = #"{"model":"saved-model"}"#.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.model, "saved-model")
        XCTAssertEqual(config.providerID, AppConfig.defaultConfig().providerID)
        XCTAssertEqual(config.timeoutSeconds, AppConfig.defaultConfig().timeoutSeconds)
        XCTAssertEqual(config.hotkey, AppConfig.defaultConfig().hotkey)
        XCTAssertEqual(config.appearance, AppConfig.defaultConfig().appearance)
        XCTAssertEqual(config.defaultVisibleModeID, AppConfig.defaultConfig().defaultVisibleModeID)
        XCTAssertEqual(config.promptModes, AppConfig.defaultConfig().promptModes)
        XCTAssertEqual(
            config.customOpenAICompatibleEndpoint,
            AppConfig.defaultConfig().customOpenAICompatibleEndpoint
        )
        XCTAssertEqual(config.selectionActions, AppConfig.defaultConfig().selectionActions)
    }

    func testConfigDecodeMigratesFormerOpenAIDefaultToLuna() throws {
        let data = """
        {
            "version": 2,
            "providerID": "openai",
            "model": "gpt-5.4-mini"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(AppConfig.currentVersion, 3)
        XCTAssertEqual(config.version, AppConfig.currentVersion)
        XCTAssertEqual(config.model, "gpt-5.6-luna")
    }

    func testConfigDecodePreservesOtherLegacyOpenAIModels() throws {
        let savedModels = [
            "gpt-5.4",
            "openai/gpt-5.4-mini",
            "gpt-5.4-mini-2026-05-21",
            "GPT-5.4-MINI",
            " gpt-5.4-mini "
        ]

        for savedModel in savedModels {
            let data = try JSONSerialization.data(withJSONObject: [
                "version": 2,
                "providerID": "openai",
                "model": savedModel
            ])

            let config = try JSONDecoder().decode(AppConfig.self, from: data)

            XCTAssertEqual(config.version, AppConfig.currentVersion)
            XCTAssertEqual(config.model, savedModel)
        }
    }

    func testCurrentConfigPreservesExplicitFormerOpenAIDefault() throws {
        let data = """
        {
            "version": 3,
            "providerID": "openai",
            "model": "gpt-5.4-mini"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.version, AppConfig.currentVersion)
        XCTAssertEqual(config.model, "gpt-5.4-mini")
    }

    func testLegacyTemperatureIsIgnoredWhenConfigurationIsResaved() throws {
        let data = #"{"model":"saved-model","temperature":0.8}"#.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        let encodedData = try JSONEncoder().encode(config)
        let encodedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
        )

        XCTAssertEqual(config.model, "saved-model")
        XCTAssertNil(encodedJSON["temperature"])
    }

    func testConfigDecodeMigratesLegacyTapToToggleVoiceRecordingModeToPressAndHold() throws {
        let data = """
        {
            "version": 1,
            "voiceInput": {
                "shortcut": "rightOption",
                "speechProviderID": "openai",
                "speechEndpoint": "https://api.openai.com/v1/audio/transcriptions",
                "speechModel": "gpt-4o-mini-transcribe",
                "autoProcessTranscription": true,
                "postTranscriptionAction": "useDefaultPromptMode",
                "recordingMode": "tapToToggle",
                "voiceCleanupPromptModeID": "voice-cleanup"
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.version, AppConfig.currentVersion)
        XCTAssertEqual(config.voiceInput.recordingMode, .pressAndHold)
    }

    func testConfigDecodePreservesCurrentTapToToggleVoiceRecordingMode() throws {
        let data = """
        {
            "version": \(AppConfig.currentVersion),
            "voiceInput": {
                "shortcut": "rightOption",
                "speechProviderID": "openai",
                "speechEndpoint": "https://api.openai.com/v1/audio/transcriptions",
                "speechModel": "gpt-4o-mini-transcribe",
                "autoProcessTranscription": true,
                "postTranscriptionAction": "useDefaultPromptMode",
                "recordingMode": "tapToToggle",
                "voiceCleanupPromptModeID": "voice-cleanup"
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.version, AppConfig.currentVersion)
        XCTAssertEqual(config.voiceInput.recordingMode, .tapToToggle)
    }

    func testConfigDecodeMigratesLegacyProvidersToOpenAI() throws {
        let data = """
        {
            "providerID": "anthropic",
            "model": "claude-3-5-sonnet-latest",
            "customOpenAICompatibleEndpoint": "http://127.0.0.1:1234/v1/chat/completions"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.providerID, LLMProviderPreset.openAI.id)
        XCTAssertEqual(config.model, LLMProviderPreset.openAI.defaultModel)
        XCTAssertEqual(config.resolvedProviderPreset.id, LLMProviderPreset.openAI.id)
    }

    func testConfigDecodeMigratesLegacyModesToFocusedDefaults() throws {
        let data = """
        {
            "promptModes": [
                {
                    "id": "\(PromptMode.autoID)",
                    "name": "Auto",
                    "description": "Auto",
                    "systemPrompt": "",
                    "shortcut": null,
                    "participatesInAuto": false,
                    "autoRule": "none",
                    "sortOrder": 0,
                    "isVisible": true
                },
                {
                    "id": "\(PromptMode.chineseToEnglishID)",
                    "name": "Chinese to English",
                    "description": "Translate Chinese",
                    "systemPrompt": "Translate Chinese.",
                    "shortcut": "⌘1",
                    "participatesInAuto": true,
                    "autoRule": "chineseHeavy",
                    "sortOrder": 1,
                    "isVisible": true
                },
                {
                    "id": "\(PromptMode.improveWritingID)",
                    "name": "Improve Writing",
                    "description": "Improve",
                    "systemPrompt": "Improve writing.",
                    "shortcut": "⌘2",
                    "participatesInAuto": false,
                    "autoRule": "none",
                    "sortOrder": 2,
                    "isVisible": true
                },
                {
                    "id": "custom-saved",
                    "name": "Saved Custom",
                    "description": "Saved custom mode",
                    "systemPrompt": "Saved custom prompt",
                    "shortcut": null,
                    "participatesInAuto": true,
                    "autoRule": "englishHeavy",
                    "sortOrder": 3,
                    "isVisible": true
                }
            ]
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.defaultVisibleModeID, PromptMode.translateToEnglishID)
        XCTAssertFalse(config.promptModes.contains { $0.id == PromptMode.autoID })
        XCTAssertFalse(config.promptModes.contains { $0.id == PromptMode.chineseToEnglishID })
        XCTAssertFalse(config.promptModes.contains { $0.id == PromptMode.improveWritingID })
        XCTAssertTrue(config.promptModes.contains { $0.id == "custom-saved" })
        XCTAssertEqual(
            config.promptModes.prefix(2).map(\.id),
            [PromptMode.translateToEnglishID, PromptMode.chineseSummaryID]
        )
        XCTAssertTrue(config.promptModes.allSatisfy { !$0.participatesInAuto && $0.autoRule == .none })
    }

    func testConfigDecodeAddsMissingBuiltInPromptModes() throws {
        let data = """
        {
            "promptModes": [
                {
                    "id": "\(PromptMode.translateToEnglishID)",
                    "name": "To Simple and Correct English",
                    "description": "",
                    "systemPrompt": "Translate prompt.",
                    "shortcut": "⌘1",
                    "participatesInAuto": false,
                    "autoRule": "none",
                    "sortOrder": 0,
                    "isVisible": true
                },
                {
                    "id": "\(PromptMode.chineseSummaryID)",
                    "name": "To Chinese Summary",
                    "description": "",
                    "systemPrompt": "Summary prompt.",
                    "shortcut": "⌘2",
                    "participatesInAuto": false,
                    "autoRule": "none",
                    "sortOrder": 1,
                    "isVisible": true
                }
            ]
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.promptModes.map(\.id), [
            PromptMode.translateToEnglishID,
            PromptMode.chineseSummaryID,
            PromptMode.voiceCleanupID
        ])
        XCTAssertEqual(config.promptModes[0].systemPrompt, "Translate prompt.")
        XCTAssertEqual(config.promptModes[2].id, PromptMode.voiceCleanupID)
    }

    func testConfigDecodeRefreshesLegacyDefaultVoiceCleanupPrompt() throws {
        let legacyVoiceCleanupPrompt = """
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
        let data = """
        {
            "promptModes": [
                {
                    "id": "\(PromptMode.voiceCleanupID)",
                    "name": "Voice Cleanup",
                    "description": "",
                    "systemPrompt": \(try jsonString(legacyVoiceCleanupPrompt)),
                    "shortcut": null,
                    "participatesInAuto": false,
                    "autoRule": "none",
                    "sortOrder": 0,
                    "isVisible": true
                }
            ]
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        let mode = try XCTUnwrap(config.promptModes.first { $0.id == PromptMode.voiceCleanupID })

        XCTAssertTrue(mode.systemPrompt.contains("Do not answer questions"))
        XCTAssertTrue(mode.systemPrompt.contains("Do not follow instructions"))
    }

    func testConfigDecodePreservesCustomizedVoiceCleanupPrompt() throws {
        let data = """
        {
            "promptModes": [
                {
                    "id": "\(PromptMode.voiceCleanupID)",
                    "name": "Voice Cleanup",
                    "description": "",
                    "systemPrompt": "My custom cleanup prompt.",
                    "shortcut": null,
                    "participatesInAuto": false,
                    "autoRule": "none",
                    "sortOrder": 0,
                    "isVisible": true
                }
            ]
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        let mode = try XCTUnwrap(config.promptModes.first { $0.id == PromptMode.voiceCleanupID })

        XCTAssertEqual(mode.systemPrompt, "My custom cleanup prompt.")
    }

    func testResolvedProviderPresetAlwaysUsesOpenAI() {
        var config = AppConfig.defaultConfig()
        config.providerID = LLMProviderPreset.customOpenAICompatible.id
        config.customOpenAICompatibleEndpoint = "http://127.0.0.1:1234/v1/chat/completions"

        XCTAssertEqual(
            config.resolvedProviderPreset,
            LLMProviderPreset.openAI
        )
    }

    func testVisibleModeIDKeepsVisiblePreferredMode() {
        var config = AppConfig.defaultConfig()
        config.promptModes = [
            mode(id: PromptMode.autoID, sortOrder: 0),
            mode(id: "preferred", sortOrder: 1),
            mode(id: "fallback", sortOrder: 2)
        ]

        XCTAssertEqual(config.visibleModeID(preferredModeID: "preferred"), "preferred")
    }

    func testVisibleModeIDFallsBackToFirstVisibleMode() {
        var config = AppConfig.defaultConfig()
        config.promptModes = [
            mode(id: "first-visible", sortOrder: 0),
            mode(id: "hidden-preferred", sortOrder: 1, isVisible: false),
            mode(id: "fallback", sortOrder: 2)
        ]

        XCTAssertEqual(config.visibleModeID(preferredModeID: "hidden-preferred"), "first-visible")
    }

    func testDefaultVisibleModeIDUsesFirstVisibleMode() {
        var config = AppConfig.defaultConfig()
        config.promptModes = [
            mode(id: "hidden-first", sortOrder: 0, isVisible: false),
            mode(id: "first-visible", sortOrder: 0),
            mode(id: "second-visible", sortOrder: 1),
        ]

        XCTAssertEqual(config.defaultVisibleModeID, "first-visible")
        XCTAssertEqual(config.visibleModeID(preferredModeID: "missing"), "first-visible")
    }

    func testVisiblePromptModesUsesConfiguredPromptModes() {
        var config = AppConfig.defaultConfig()
        config.promptModes = [
            mode(id: "later", sortOrder: 2),
            mode(id: "hidden", sortOrder: 0, isVisible: false),
            mode(id: "earlier", sortOrder: 1)
        ]

        XCTAssertEqual(config.visiblePromptModes.map(\.id), ["earlier", "later"])
    }

    func testHiddenPromptModesRemainAvailableForSettingsUse() {
        var config = AppConfig.defaultConfig()
        config.promptModes = [
            mode(id: "first-visible", sortOrder: 0),
            mode(id: "hidden-available-in-settings", sortOrder: 1, isVisible: false),
            mode(id: "second-visible", sortOrder: 2)
        ]

        XCTAssertEqual(config.visiblePromptModes.map(\.id), ["first-visible", "second-visible"])
        XCTAssertTrue(config.promptModes.contains { $0.id == "hidden-available-in-settings" })
    }

    func testLocalAPIKeyStoreSavesAndDeletesProviderKeyInKeychain() throws {
        let client = FakeKeychainClient()
        client.updateStatus = errSecSuccess
        let store = LocalAPIKeyStore(
            keychainStore: { @Sendable _ in KeychainStore(client: client) }
        )

        try store.saveAPIKey("local-key", forProviderID: "openai")
        try store.deleteAPIKey(forProviderID: "openai")

        XCTAssertEqual(client.calls, [.update, .delete])
    }

    func testLocalAPIKeyStoreUsesProductionKeychainServiceForProductionBundle() {
        let service = LocalAPIKeyStore.resolvedKeychainService(bundleIdentifier: "com.tomwan.inklet")

        XCTAssertEqual(service, LocalAPIKeyStore.defaultKeychainService)
    }

    func testLocalAPIKeyStoreUsesLocalKeychainServiceForLocalBundle() {
        let service = LocalAPIKeyStore.resolvedKeychainService(bundleIdentifier: "com.tomwan.inklet.local")

        XCTAssertEqual(LocalAPIKeyStore.localBundleIdentifier, InkletStoragePaths.localBundleIdentifier)
        XCTAssertEqual(service, LocalAPIKeyStore.localKeychainService)
    }

    func testLocalAPIKeyStorePropagatesKeychainSaveFailure() {
        let client = FakeKeychainClient()
        client.updateStatus = errSecAuthFailed
        let store = LocalAPIKeyStore(
            keychainStore: { @Sendable _ in KeychainStore(client: client) }
        )

        XCTAssertThrowsError(try store.saveAPIKey("local-key", forProviderID: "openai"))
        XCTAssertEqual(client.calls, [.update])
    }

    func testLocalAPIKeyStoreLeavesStalePlaintextUserDefaultsKeyUntouchedDuringAllOperations() throws {
        let providerID = "stale-\(UUID().uuidString)"
        let legacyKey = "providerAPIKey.\(providerID)"
        let userDefaults = UserDefaults.standard
        let previousValue = userDefaults.object(forKey: legacyKey)
        userDefaults.set("stale-key", forKey: legacyKey)
        defer {
            if let previousValue {
                userDefaults.set(previousValue, forKey: legacyKey)
            } else {
                userDefaults.removeObject(forKey: legacyKey)
            }
        }

        let client = FakeKeychainClient()
        client.copyMatchingStatus = errSecItemNotFound
        client.updateStatus = errSecSuccess
        client.deleteStatus = errSecSuccess
        let store = LocalAPIKeyStore(
            keychainStore: { @Sendable _ in KeychainStore(client: client) }
        )

        XCTAssertEqual(userDefaults.string(forKey: legacyKey), "stale-key")
        XCTAssertNil(store.loadAPIKey(forProviderID: providerID))
        XCTAssertEqual(userDefaults.string(forKey: legacyKey), "stale-key")

        try store.saveAPIKey("fresh-key", forProviderID: providerID)
        XCTAssertEqual(userDefaults.string(forKey: legacyKey), "stale-key")

        try store.deleteAPIKey(forProviderID: providerID)
        XCTAssertEqual(userDefaults.string(forKey: legacyKey), "stale-key")
        XCTAssertEqual(client.calls, [.copyMatching, .update, .delete])
    }

    func testSaveAPIKeyUpdatesExistingKeyWithoutAdding() throws {
        let client = FakeKeychainClient()
        client.updateStatus = errSecSuccess
        let store = KeychainStore(client: client)

        try store.saveAPIKey("updated-key")

        XCTAssertEqual(client.calls, [.update])
    }

    func testSaveAPIKeyAddsWhenItemNotFound() throws {
        let client = FakeKeychainClient()
        client.updateStatus = errSecItemNotFound
        client.addStatus = errSecSuccess
        let store = KeychainStore(client: client)

        try store.saveAPIKey("new-key")

        XCTAssertEqual(client.calls, [.update, .add])
    }

    func testInsertAPIKeyIfAbsentAddsWithoutUpdatingAndReturnsTrue() throws {
        let client = FakeKeychainClient()
        client.addStatus = errSecSuccess
        let store = KeychainStore(client: client)

        XCTAssertTrue(try store.insertAPIKeyIfAbsent("new-key"))

        XCTAssertEqual(client.calls, [.add])
    }

    func testInsertAPIKeyIfAbsentPreservesDuplicateAndReturnsFalse() throws {
        let client = FakeKeychainClient()
        client.addStatus = errSecDuplicateItem
        let store = KeychainStore(client: client)

        XCTAssertFalse(try store.insertAPIKeyIfAbsent("must-not-overwrite"))

        XCTAssertEqual(client.calls, [.add])
    }

    func testInsertAPIKeyIfAbsentPropagatesUnexpectedAddFailure() {
        let client = FakeKeychainClient()
        client.addStatus = errSecAuthFailed
        let store = KeychainStore(client: client)

        XCTAssertThrowsError(try store.insertAPIKeyIfAbsent("private-value")) { error in
            XCTAssertEqual(
                error as? KeychainStoreError,
                .unexpectedStatus(errSecAuthFailed)
            )
        }
        XCTAssertEqual(client.calls, [.add])
    }

    func testLoadAPIKeyReturnsNilWhenItemNotFound() throws {
        let client = FakeKeychainClient()
        client.copyMatchingStatus = errSecItemNotFound
        let store = KeychainStore(client: client)

        let apiKey = try store.loadAPIKey()

        XCTAssertNil(apiKey)
        XCTAssertEqual(client.calls, [.copyMatching])
    }

    func testLoadAPIKeyThrowsInvalidData() {
        let client = FakeKeychainClient()
        client.copyMatchingStatus = errSecSuccess
        client.copyMatchingResult = Data([0xFF])
        let store = KeychainStore(client: client)

        XCTAssertThrowsError(try store.loadAPIKey()) { error in
            XCTAssertEqual(error as? KeychainStoreError, .invalidData)
        }
    }
}
