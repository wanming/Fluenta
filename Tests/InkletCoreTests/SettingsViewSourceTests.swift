import XCTest
import Security
@testable import Inklet
@testable import InkletCore

final class SettingsViewSourceTests: XCTestCase {
    func testTemperatureSettingIsRemoved() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("settings.row.temperature"))
        XCTAssertFalse(source.contains("settings.help.temperature"))
        XCTAssertFalse(source.contains("config.temperature"))
    }

    func testTemperatureLocalizationKeysAreRemoved() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/InkletLocalization.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("settings.row.temperature"))
        XCTAssertFalse(source.contains("settings.help.temperature"))
    }

    func testSelectionActionsExposeSafeForceSelectionChoicesAndCopyOptIn() throws {
        let source = try settingsViewSource()
        let panelRange = try XCTUnwrap(source.range(of: "private var selectionActionsPanel"))
        let historyRange = try XCTUnwrap(source.range(
            of: "\n    private var historyPanel",
            range: panelRange.upperBound..<source.endIndex
        ))
        let panelBlock = source[panelRange.lowerBound..<historyRange.lowerBound]

        XCTAssertTrue(panelBlock.contains("ForEach(SelectionForceSelectionMode.settingsCases)"))
        XCTAssertFalse(panelBlock.contains("ForEach(SelectionForceSelectionMode.allCases)"))
        XCTAssertTrue(panelBlock.contains("settings.row.allowSimulatedCopyFallback"))
        XCTAssertTrue(panelBlock.contains("settings.help.allowSimulatedCopyFallback"))
        XCTAssertTrue(panelBlock.contains("$model.config.selectionActions.allowsSimulatedCopyFallback"))
        XCTAssertTrue(panelBlock.contains(
            ".disabled(model.config.selectionActions.forceSelectionMode == .disabled)"
        ))
    }

    func testWriteAssistantExposesRecoveryModelWithoutEditableEndpoint() throws {
        let source = try settingsViewSource()

        XCTAssertFalse(source.contains("case voiceWriteAssistant"))
        XCTAssertTrue(source.contains("settings.group.writing"))
        XCTAssertTrue(source.contains("settings.group.dictation"))
        XCTAssertTrue(source.contains("$model.config.voiceInput.shortcut"))
        XCTAssertTrue(source.contains("settings.row.microphone"))
        XCTAssertTrue(source.contains("selectedMicrophoneBinding"))
        XCTAssertFalse(source.contains("$model.config.voiceInput.speechEndpoint"))
        XCTAssertTrue(source.contains("$model.config.voiceInput.speechModel"))
        XCTAssertTrue(source.contains("settings.group.dictationAdvanced"))
        XCTAssertTrue(source.contains("settings.row.fallbackSpeechModel"))
        XCTAssertFalse(source.contains("settings.row.fallbackSpeechEndpoint"))
        XCTAssertFalse(source.contains("settings.help.fallbackSpeechEndpoint"))
        XCTAssertFalse(source.contains("settings.error.invalidFallbackSpeechEndpoint"))
        XCTAssertFalse(source.contains("URL(string: config.voiceInput.speechEndpoint"))
        XCTAssertFalse(source.contains("speechEndpoint.scheme"))
        XCTAssertFalse(source.contains("speechEndpoint.host"))
        XCTAssertFalse(source.contains("voice.error.invalidSpeechEndpoint"))
        XCTAssertFalse(source.contains("settings.voiceRecordingMode.holdKey"))
    }

    func testRetiredVoiceWorkflowControlsAreAbsent() throws {
        let source = try settingsViewSource()

        for retired in [
            "VoiceInputConfig.RecordingMode",
            "VoiceInputConfig.PostTranscriptionAction",
            "selectedSpeechProfile",
            "voiceCleanupModes",
            "autoProcessTranscription",
            "voiceCleanupPromptModeID"
        ] {
            XCTAssertFalse(source.contains(retired), retired)
        }
    }

    @MainActor
    func testFlushWithoutEditsPreservesRawConfigAndAllowsAssistedImport() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsNoEditFlush-\(UUID().uuidString)", isDirectory: true)
        let homeDirectory = testRoot.appendingPathComponent("home", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("destination", isDirectory: true)
        let historyURL = testRoot.appendingPathComponent("history.jsonl")
        let bundleIdentifier = "com.tomwan.inklet.settings-no-edit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: bundleIdentifier))
        defaults.removePersistentDomain(forName: bundleIdentifier)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: bundleIdentifier)
            try? FileManager.default.removeItem(at: testRoot)
        }

        let rawCurrentConfig = Data(#"{"version":1}"#.utf8)
        defaults.set(rawCurrentConfig, forKey: UserDefaultsConfigStore.defaultKey)
        XCTAssertTrue(defaults.synchronize())

        let keychainClient = SettingsTestKeychainClient(storedValue: " existing-key ")
        let apiKeyStore = LocalAPIKeyStore { providerID in
            KeychainStore(service: "settings-test", account: providerID, client: keychainClient)
        }
        let model = SettingsViewModel(
            configStore: UserDefaultsConfigStore(userDefaults: defaults),
            apiKeyStore: apiKeyStore,
            modelCatalogService: ModelCatalogService(
                userDefaults: defaults,
                bundledFallbackData: { nil }
            ),
            historyStore: JSONLHistoryStore(fileURL: historyURL)
        )

        XCTAssertEqual(defaults.data(forKey: UserDefaultsConfigStore.defaultKey), rawCurrentConfig)
        XCTAssertTrue(model.flushPendingEdits())
        XCTAssertEqual(defaults.data(forKey: UserDefaultsConfigStore.defaultKey), rawCurrentConfig)
        XCTAssertEqual(keychainClient.mutationCallCount, 0)

        var baseline: [String: PreferenceFingerprint] = [:]
        let currentDomain = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        for key in InkletPreferenceKeys.recognizedLegacyKeys {
            baseline[key] = try LegacyPreferenceFingerprinter.fingerprint(of: currentDomain[key])
        }
        let stateStore = SettingsTestMigrationStateStore(baseline: baseline)
        let legacyRoot = LegacySandboxDataMigrator.expectedLegacyDataRoot(
            bundleIdentifier: bundleIdentifier,
            homeDirectoryURL: homeDirectory
        )
        let preferencesURL = legacyRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist")
        try FileManager.default.createDirectory(
            at: preferencesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyConfig = Data(#"{"version":1,"model":"legacy-model"}"#.utf8)
        let preferences = try PropertyListSerialization.data(
            fromPropertyList: [InkletPreferenceKeys.appConfig: legacyConfig],
            format: .binary,
            options: 0
        )
        try preferences.write(to: preferencesURL, options: .atomic)

        let storagePaths = InkletStoragePaths(
            bundleIdentifier: bundleIdentifier,
            applicationSupportRootURL: destinationRoot,
            temporaryDirectory: testRoot
        )
        let migrator = LegacySandboxDataMigrator(
            bundleIdentifier: bundleIdentifier,
            storagePaths: storagePaths,
            homeDirectoryURL: homeDirectory,
            defaults: defaults,
            fileSystem: FileManagerLegacyMigrationFileSystem(),
            stateStore: stateStore,
            keychainStore: { providerID in
                KeychainStore(service: "migration-test", account: providerID, client: keychainClient)
            },
            lock: LegacyMigrationLock(fileURL: storagePaths.migrationLockFileURL)
        )

        let outcome = migrator.migrateUserSelectedData(at: legacyRoot)

        XCTAssertEqual(outcome.results[.preferences], .completed(changedDestination: true))
        XCTAssertEqual(defaults.data(forKey: UserDefaultsConfigStore.defaultKey), legacyConfig)
    }

    func testMigrationWorkflowIdleWaitsForSettingsAsyncWorkToQuiesce() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("@Published private(set) var isMigrationWorkflowIdle = true"))
        XCTAssertTrue(source.contains(
            "private var pronunciationPreviewTasks: [UUID: Task<Void, Never>] = [:]"
        ))
        XCTAssertTrue(source.contains("private var pronunciationPreviewTaskID: UUID?"))
        XCTAssertTrue(source.contains("private var modelCatalogRefreshTaskID: UUID?"))
        XCTAssertTrue(source.contains("func waitForMigrationMaintenanceQuiescence() async"))
        XCTAssertTrue(source.contains("let previewTasks = Array(pronunciationPreviewTasks.values)"))
        XCTAssertTrue(source.contains("for task in previewTasks"))
        XCTAssertTrue(source.contains("await task.value"))
        XCTAssertTrue(source.contains("await modelCatalogRefreshTask?.value"))

        let preview = try sourceScope(
            startingAt: "func previewPronunciationVoice()",
            endingBefore: "func resetSelectionTranslationPrompt()",
            in: source
        )
        XCTAssertTrue(preview.contains(
            "guard !Task.isCancelled, self?.pronunciationPreviewTaskID == taskID else { return }"
        ))

        let idleRefresh = try sourceScope(
            startingAt: "private func refreshMigrationWorkflowIdle()",
            endingBefore: "func openAccessibilitySettings()",
            in: source
        )
        XCTAssertTrue(idleRefresh.contains("pronunciationPreviewState == nil"))
        XCTAssertTrue(idleRefresh.contains("pronunciationPreviewTasks.isEmpty"))
        XCTAssertTrue(idleRefresh.contains("modelCatalogRefreshTask == nil"))
        XCTAssertTrue(idleRefresh.contains("!isRefreshingModelCatalog"))

        let maintenance = try sourceScope(
            startingAt: "func setMigrationMaintenanceActive(_ isActive: Bool)",
            endingBefore: "func waitForMigrationMaintenanceQuiescence() async",
            in: source
        )
        XCTAssertTrue(maintenance.contains("pronunciationPreviewTasks.values.forEach"))
        XCTAssertTrue(maintenance.contains("modelCatalogRefreshTask?.cancel()"))
        XCTAssertFalse(maintenance.contains("modelCatalogRefreshTask = nil"))
    }

    func testHistoryRowsExposeSingleCopyResultAction() throws {
        let source = try settingsViewSource()
        let rowRange = try XCTUnwrap(source.range(of: "private func historyRow"))
        let textBlockRange = try XCTUnwrap(source.range(
            of: "\n    private func historyTextBlock",
            range: rowRange.upperBound..<source.endIndex
        ))
        let rowBlock = source[rowRange.lowerBound..<textBlockRange.lowerBound]
        let copyButtonCount = rowBlock.components(separatedBy: "historyCopyButton(").count - 1

        XCTAssertEqual(copyButtonCount, 1)
        XCTAssertTrue(rowBlock.contains("settings.history.copyResult"))
        XCTAssertFalse(rowBlock.contains("settings.history.copyOriginal"))
    }

    private func settingsViewSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/SettingsView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func sourceScope(
        startingAt startToken: String,
        endingBefore endToken: String,
        in source: String
    ) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: startToken))
        let end = try XCTUnwrap(source.range(of: endToken, range: start.upperBound..<source.endIndex))
        return source[start.lowerBound..<end.lowerBound]
    }
}

private final class SettingsTestMigrationStateStore: LegacyMigrationStateStore, @unchecked Sendable {
    private var versions: [LegacyMigrationComponent: Int] = [:]
    private var baseline: [String: PreferenceFingerprint]?

    init(baseline: [String: PreferenceFingerprint]) {
        self.baseline = baseline
    }

    func reload() throws {}

    func completedVersion(for component: LegacyMigrationComponent) throws -> Int? {
        versions[component]
    }

    func setCompletedVersion(_ version: Int, for component: LegacyMigrationComponent) throws {
        versions[component] = version
    }

    func preferenceBaseline() throws -> [String: PreferenceFingerprint]? {
        baseline
    }

    func setPreferenceBaseline(_ baseline: [String: PreferenceFingerprint]) throws {
        self.baseline = baseline
    }
}

private final class SettingsTestKeychainClient: KeychainClient, @unchecked Sendable {
    private let storedValue: String?
    private(set) var mutationCallCount = 0

    init(storedValue: String? = nil) {
        self.storedValue = storedValue
    }

    func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard let storedValue else { return errSecItemNotFound }
        result?.pointee = Data(storedValue.utf8) as CFData
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        mutationCallCount += 1
        return errSecItemNotFound
    }

    func add(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        mutationCallCount += 1
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        mutationCallCount += 1
        return errSecSuccess
    }
}
