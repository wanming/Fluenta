import AppKit
import Carbon
import Combine
import SwiftUI
import InkletCore

private enum PronunciationPreviewState: Equatable {
    case loading(SelectionPronunciationVoice)
    case playing(SelectionPronunciationVoice)

    func matches(_ voice: SelectionPronunciationVoice) -> Bool {
        switch self {
        case .loading(let activeVoice), .playing(let activeVoice):
            activeVoice == voice
        }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var config: AppConfig
    @Published var message: String
    @Published var providerAPIKey: String
    @Published var selectedPromptModeID: String
    @Published var interfaceLanguage: InterfaceLanguage
    @Published var cachedProviderModels: [String: [String]]
    @Published var isRefreshingModelCatalog: Bool
    @Published var isEditingCustomModel: Bool
    @Published var microphoneOptions: [MicrophoneDeviceOption]
    @Published fileprivate var pronunciationPreviewState: PronunciationPreviewState?
    @Published var permissionRefreshID: UUID
    @Published var historyItems: [HistoryItem]
    @Published var historyFilter: HistorySource?
    @Published private(set) var isMigrationMaintenanceActive = false
    @Published private(set) var isMigrationWorkflowIdle = true

    private let configStore: UserDefaultsConfigStore
    private let apiKeyStore: LocalAPIKeyStore
    private let modelCatalogService: ModelCatalogService
    private let historyStore: any HistoryStore
    private let microphoneDeviceCatalog: MicrophoneDeviceCatalog
    private let pronunciationPreviewPlaybackService: SpeechPlaybackService
    private var autoSaveCancellable: AnyCancellable?
    private var pronunciationPreviewTasks: [UUID: Task<Void, Never>] = [:]
    private var pronunciationPreviewTaskID: UUID?
    private var modelCatalogRefreshTask: Task<Void, Never>?
    private var modelCatalogRefreshTaskID: UUID?
    private var savedConfig: AppConfig
    private var savedProviderAPIKey: String
    private var savedInterfaceLanguage: InterfaceLanguage

    static let customModelMenuID = "__custom_model__"

    init(
        configStore: UserDefaultsConfigStore = UserDefaultsConfigStore(),
        apiKeyStore: LocalAPIKeyStore = LocalAPIKeyStore(),
        modelCatalogService: ModelCatalogService = ModelCatalogService(),
        historyStore: any HistoryStore = JSONLHistoryStore(),
        microphoneDeviceCatalog: MicrophoneDeviceCatalog = MicrophoneDeviceCatalog()
    ) {
        var loadedConfig = (try? configStore.load()) ?? AppConfig.defaultConfig()
        self.configStore = configStore
        self.apiKeyStore = apiKeyStore
        self.modelCatalogService = modelCatalogService
        self.historyStore = historyStore
        self.microphoneDeviceCatalog = microphoneDeviceCatalog
        self.pronunciationPreviewPlaybackService = SpeechPlaybackService()
        loadedConfig.providerID = LLMProviderPreset.openAI.id
        self.config = loadedConfig
        self.savedConfig = loadedConfig
        self.message = ""
        self.interfaceLanguage = InkletLanguageStore.selectedLanguage
        self.savedInterfaceLanguage = InkletLanguageStore.selectedLanguage
        let loadedProviderAPIKey = apiKeyStore.loadAPIKey(forProviderID: LLMProviderPreset.openAI.id) ?? ""
        self.providerAPIKey = loadedProviderAPIKey
        self.savedProviderAPIKey = loadedProviderAPIKey
        self.selectedPromptModeID = loadedConfig.promptModes.sorted { $0.sortOrder < $1.sortOrder }.first?.id
            ?? PromptMode.translateToEnglishID
        self.cachedProviderModels = Dictionary(
            uniqueKeysWithValues: LLMProviderPreset.all.compactMap { preset in
                guard let modelIDs = modelCatalogService.cachedModelIDs(for: preset.id) else {
                    return nil
                }
                return (preset.id, modelIDs)
            }
        )
        self.isRefreshingModelCatalog = false
        self.isEditingCustomModel = false
        self.microphoneOptions = microphoneDeviceCatalog.options()
        self.pronunciationPreviewState = nil
        self.permissionRefreshID = UUID()
        self.historyItems = (try? historyStore.load()).map { Array($0.reversed()) } ?? []
        self.historyFilter = nil

        self.pronunciationPreviewPlaybackService.onFinish = { [weak self] in
            self?.pronunciationPreviewState = nil
            self?.refreshMigrationWorkflowIdle()
        }
        installAutoSave()
    }

    var selectedProvider: LLMProviderPreset {
        LLMProviderPreset.openAI
    }

    var filteredHistoryItems: [HistoryItem] {
        guard let historyFilter else {
            return historyItems
        }
        return historyItems.filter { $0.source == historyFilter }
    }

    var isCustomOpenAICompatibleProvider: Bool {
        false
    }

    var selectedProviderModelOptions: [String] {
        guard !isCustomOpenAICompatibleProvider else {
            return []
        }

        var seen = Set<String>()
        var options: [String] = []

        for modelID in cachedProviderModels[LLMProviderPreset.openAI.id] ?? [] {
            if seen.insert(modelID).inserted {
                options.append(modelID)
            }
        }

        if seen.insert(selectedProvider.defaultModel).inserted {
            options.insert(selectedProvider.defaultModel, at: 0)
        }

        return options
    }

    var selectedModelMenuValue: String {
        if isEditingCustomModel {
            return Self.customModelMenuID
        }

        return selectedProviderModelOptions.contains(config.model) ? config.model : Self.customModelMenuID
    }

    var shouldShowCustomModelField: Bool {
        isCustomOpenAICompatibleProvider || selectedModelMenuValue == Self.customModelMenuID
    }

    var selectedModelIsDefault: Bool {
        config.model.trimmingCharacters(in: .whitespacesAndNewlines) == selectedProvider.defaultModel
    }

    var selectedPromptModeIndex: Int? {
        config.promptModes.firstIndex { $0.id == selectedPromptModeID }
    }

    var orderedPromptModes: [PromptMode] {
        config.promptModes.sorted { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder {
                return lhs.name < rhs.name
            }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    var isAccessibilityTrusted: Bool {
        AccessibilityPermissionService().isTrusted
    }

    func refreshPermissions() {
        permissionRefreshID = UUID()
    }

    func reloadHistory() {
        do {
            historyItems = Array(try historyStore.load().reversed())
        } catch {
            historyItems = []
            message = L10n.text("settings.history.error.loadFailed")
        }
    }

    func clearHistory() {
        guard !isMigrationMaintenanceActive else { return }
        do {
            try historyStore.clear()
            historyItems = []
            message = L10n.text("settings.history.cleared")
        } catch {
            message = L10n.text("settings.history.error.clearFailed")
        }
    }

    func refreshMicrophoneOptions() {
        microphoneOptions = microphoneDeviceCatalog.options()
        if let microphoneDeviceID = config.voiceInput.microphoneDeviceID,
           !microphoneOptions.contains(where: { $0.deviceID == microphoneDeviceID }) {
            config.voiceInput.microphoneDeviceID = nil
        }
    }

    var selectedMicrophoneMenuID: String {
        get {
            guard let microphoneDeviceID = config.voiceInput.microphoneDeviceID,
                  microphoneOptions.contains(where: { $0.deviceID == microphoneDeviceID })
            else {
                return MicrophoneDeviceOption.systemDefaultID
            }
            return microphoneDeviceID
        }
        set {
            config.voiceInput.microphoneDeviceID = newValue == MicrophoneDeviceOption.systemDefaultID ? nil : newValue
        }
    }

    func modelMenuTitle(for modelID: String) -> String {
        if modelID == config.model, !selectedModelIsDefault {
            return "\(modelID) *"
        }
        return modelID
    }

    func selectModelMenuValue(_ value: String) {
        if value == Self.customModelMenuID {
            isEditingCustomModel = true
            return
        }

        isEditingCustomModel = false
        config.model = value
        save()
    }

    func previewPronunciationVoice() {
        guard !isMigrationMaintenanceActive else { return }
        let voice = config.selectionActions.pronunciationVoice
        let speed = config.selectionActions.pronunciationSpeed
        if let pronunciationPreviewTaskID {
            pronunciationPreviewTasks[pronunciationPreviewTaskID]?.cancel()
        }
        pronunciationPreviewPlaybackService.stop()
        pronunciationPreviewState = .loading(voice)
        let taskID = UUID()
        pronunciationPreviewTaskID = taskID

        let task = Task { [weak self] in
            defer {
                self?.pronunciationPreviewTasks[taskID] = nil
                if self?.pronunciationPreviewTaskID == taskID {
                    self?.pronunciationPreviewTaskID = nil
                }
                self?.refreshMigrationWorkflowIdle()
            }
            do {
                guard let self else { return }
                let provider = OpenAITTSProvider(apiKeyProvider: { [apiKeyStore] in
                    guard let apiKey = apiKeyStore.loadAPIKey(forProviderID: LLMProviderPreset.openAI.id),
                          !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        throw OpenAITTSError.provider(L10n.text("selection.action.missingOpenAIKey"))
                    }
                    return apiKey
                })
                let audioData = try await provider.speechAudio(OpenAITTSRequest(
                    input: SelectionPronunciationVoice.previewText(
                        interfaceLanguageCode: L10n.resolvedLanguage.localeIdentifier
                    ),
                    voice: voice.rawValue,
                    speed: speed,
                    timeoutSeconds: config.timeoutSeconds
                ))
                guard !Task.isCancelled,
                      pronunciationPreviewTaskID == taskID,
                      !isMigrationMaintenanceActive
                else {
                    return
                }
                await MainActor.run {
                    do {
                        try self.pronunciationPreviewPlaybackService.play(audioData: audioData)
                        self.pronunciationPreviewState = .playing(voice)
                    } catch {
                        self.pronunciationPreviewState = nil
                        self.message = L10n.text("selection.action.pronunciationFailed")
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, self?.pronunciationPreviewTaskID == taskID else { return }
                await MainActor.run {
                    self?.pronunciationPreviewState = nil
                    self?.message = L10n.text("selection.action.pronunciationFailed")
                }
            }
        }
        pronunciationPreviewTasks[taskID] = task
        refreshMigrationWorkflowIdle()
    }

    func resetSelectionTranslationPrompt() {
        config.selectionActions.translationPrompt = SelectionActionsConfig.defaultTranslationPrompt
        save()
    }

    func refreshModelCatalogIfNeeded() async {
        guard !isMigrationMaintenanceActive else { return }
        if let modelCatalogRefreshTask {
            await modelCatalogRefreshTask.value
            return
        }

        isRefreshingModelCatalog = true
        let taskID = UUID()
        modelCatalogRefreshTaskID = taskID
        let modelCatalogService = self.modelCatalogService
        let task = Task<Void, Never> {
            do {
                try await modelCatalogService.refreshIfNeeded()
            } catch {
                // The model picker still works with saved/default/custom values when refresh fails.
            }
        }
        modelCatalogRefreshTask = task
        refreshMigrationWorkflowIdle()
        await task.value

        guard modelCatalogRefreshTaskID == taskID else { return }
        modelCatalogRefreshTask = nil
        modelCatalogRefreshTaskID = nil
        isRefreshingModelCatalog = false
        refreshMigrationWorkflowIdle()
        guard !isMigrationMaintenanceActive else { return }
        cachedProviderModels = Dictionary(
            uniqueKeysWithValues: LLMProviderPreset.all.compactMap { preset in
                guard let modelIDs = modelCatalogService.cachedModelIDs(for: preset.id) else {
                    return nil
                }
                return (preset.id, modelIDs)
            }
        )
    }

    func addPromptMode() {
        let mode = PromptMode(
            id: "custom-\(Int(Date().timeIntervalSince1970))",
            name: L10n.text("settings.mode.newName"),
            description: "",
            systemPrompt: "",
            shortcut: nil,
            participatesInAuto: false,
            autoRule: .none,
            sortOrder: (config.promptModes.map(\.sortOrder).max() ?? 0) + 1,
            isVisible: true
        )
        config.promptModes.append(mode)
        selectedPromptModeID = mode.id
        normalizePromptModeSortOrder()
        save()
    }

    func deleteSelectedPromptMode() {
        deletePromptMode(modeID: selectedPromptModeID)
    }

    func deletePromptMode(modeID: String) {
        guard config.promptModes.count > 1 else {
            message = L10n.text("settings.error.promptModeRequired")
            return
        }

        config.promptModes.removeAll { $0.id == modeID }
        normalizePromptModeSortOrder()

        if !config.promptModes.contains(where: \.isVisible),
           let firstIndex = config.promptModes.firstIndex(where: { _ in true }) {
            config.promptModes[firstIndex].isVisible = true
        }

        if selectedPromptModeID == modeID {
            selectedPromptModeID = config.promptModes.first?.id ?? PromptMode.translateToEnglishID
        }
        save()
    }

    func movePromptModes(from source: IndexSet, to destination: Int) {
        var orderedModes = orderedPromptModes
        orderedModes.move(fromOffsets: source, toOffset: destination)

        for (sortOrder, mode) in orderedModes.enumerated() {
            guard let configIndex = config.promptModes.firstIndex(where: { $0.id == mode.id }) else {
                continue
            }
            config.promptModes[configIndex].sortOrder = sortOrder
        }
        normalizePromptModeSortOrder()
        save()
    }

    func promptModeName(modeID: String) -> String {
        guard let mode = config.promptModes.first(where: { $0.id == modeID }) else {
            return L10n.text("settings.mode.untitled")
        }
        return mode.name.isEmpty ? L10n.text("settings.mode.untitled") : mode.localizedName
    }

    func togglePromptModeVisibility(modeID: String) {
        guard let index = config.promptModes.firstIndex(where: { $0.id == modeID }) else {
            return
        }

        if config.promptModes[index].isVisible,
           config.promptModes.filter(\.isVisible).count <= 1 {
            message = L10n.text("settings.error.visibleModeRequired")
            return
        }

        config.promptModes[index].isVisible.toggle()
        save()
    }

    func promptModeVisibilityBinding(modeID: String) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                self?.config.promptModes.first(where: { $0.id == modeID })?.isVisible ?? false
            },
            set: { [weak self] newValue in
                guard let self,
                      let mode = self.config.promptModes.first(where: { $0.id == modeID }),
                      mode.isVisible != newValue
                else {
                    return
                }
                self.togglePromptModeVisibility(modeID: modeID)
            }
        )
    }

    func canMovePromptMode(modeID: String, direction: Int) -> Bool {
        guard let currentIndex = orderedPromptModes.firstIndex(where: { $0.id == modeID }) else {
            return false
        }

        return orderedPromptModes.indices.contains(currentIndex + direction)
    }

    private func normalizePromptModeSortOrder() {
        let orderedModes = orderedPromptModes
        for (sortOrder, mode) in orderedModes.enumerated() {
            guard let index = config.promptModes.firstIndex(where: { $0.id == mode.id }) else {
                continue
            }
            config.promptModes[index].sortOrder = sortOrder
        }
        config.promptModes.sort { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder {
                return lhs.name < rhs.name
            }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    @discardableResult
    func save() -> Bool {
        guard !isMigrationMaintenanceActive else { return false }
        let trimmedKey = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldSaveConfig = config != savedConfig
        let shouldSaveProviderAPIKey = providerAPIKey != savedProviderAPIKey
        let shouldSaveInterfaceLanguage = interfaceLanguage != savedInterfaceLanguage
        guard shouldSaveConfig || shouldSaveProviderAPIKey || shouldSaveInterfaceLanguage else {
            return true
        }

        do {
            if shouldSaveConfig {
                guard config.promptModes.contains(where: \.isVisible) else {
                    message = L10n.text("settings.error.visibleModeRequired")
                    return false
                }
                guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    message = L10n.text("settings.error.modelRequired")
                    return false
                }
                config.providerID = LLMProviderPreset.openAI.id

                _ = try Hotkey.parse(config.hotkey)
                try configStore.save(config)
                savedConfig = config
            }

            if shouldSaveInterfaceLanguage {
                InkletLanguageStore.selectedLanguage = interfaceLanguage
                savedInterfaceLanguage = interfaceLanguage
            }

            if shouldSaveProviderAPIKey {
                if trimmedKey.isEmpty {
                    try apiKeyStore.deleteAPIKey(forProviderID: LLMProviderPreset.openAI.id)
                } else {
                    try apiKeyStore.saveAPIKey(trimmedKey, forProviderID: LLMProviderPreset.openAI.id)
                }
                providerAPIKey = trimmedKey
                savedProviderAPIKey = trimmedKey
            }
            message = L10n.text("settings.saved")
            NotificationCenter.default.post(name: .appConfigDidSave, object: nil)
            return true
        } catch let error as HotkeyError {
            message = error.userFacingMessage
            return false
        } catch {
            message = L10n.format("settings.error.saveFailed", String(describing: error))
            return false
        }
    }

    private func installAutoSave() {
        guard !isMigrationMaintenanceActive, autoSaveCancellable == nil else {
            return
        }
        autoSaveCancellable = Publishers.CombineLatest3($config, $providerAPIKey, $interfaceLanguage)
            .dropFirst()
            .debounce(for: .milliseconds(450), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                self.save()
            }
    }

    func flushPendingEdits() -> Bool {
        autoSaveCancellable?.cancel()
        autoSaveCancellable = nil
        let didSave = hasPendingEdits ? save() : true
        installAutoSave()
        return didSave
    }

    private var hasPendingEdits: Bool {
        config != savedConfig
            || providerAPIKey != savedProviderAPIKey
            || interfaceLanguage != savedInterfaceLanguage
    }

    func setMigrationMaintenanceActive(_ isActive: Bool) {
        guard isMigrationMaintenanceActive != isActive else { return }
        isMigrationMaintenanceActive = isActive
        if isActive {
            autoSaveCancellable?.cancel()
            autoSaveCancellable = nil
            pronunciationPreviewTasks.values.forEach { $0.cancel() }
            modelCatalogRefreshTask?.cancel()
            pronunciationPreviewPlaybackService.stop()
            pronunciationPreviewState = nil
            refreshMigrationWorkflowIdle()
        } else {
            installAutoSave()
            refreshMigrationWorkflowIdle()
        }
    }

    func waitForMigrationMaintenanceQuiescence() async {
        let previewTasks = Array(pronunciationPreviewTasks.values)
        for task in previewTasks {
            await task.value
        }

        let catalogTaskID = modelCatalogRefreshTaskID
        await modelCatalogRefreshTask?.value
        if modelCatalogRefreshTaskID == catalogTaskID {
            modelCatalogRefreshTask = nil
            modelCatalogRefreshTaskID = nil
            isRefreshingModelCatalog = false
        }
        refreshMigrationWorkflowIdle()
    }

    private func refreshMigrationWorkflowIdle() {
        isMigrationWorkflowIdle = pronunciationPreviewState == nil
            && pronunciationPreviewTasks.isEmpty
            && modelCatalogRefreshTask == nil
            && !isRefreshingModelCatalog
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            message = L10n.text("settings.error.openAccessibility")
            return
        }

        NotificationCenter.default.post(
            name: .inkletDidOpenPermissionSettings,
            object: nil,
            userInfo: ["permission": PermissionSettingsDestination.accessibility.rawValue]
        )
        NSWorkspace.shared.open(url)
    }

}

extension Notification.Name {
    static let appConfigDidSave = Notification.Name("InkletAppConfigDidSave")
    static let hotkeyRecordingDidChange = Notification.Name("InkletHotkeyRecordingDidChange")
    static let inkletDidOpenPermissionSettings = Notification.Name("InkletDidOpenPermissionSettings")
    static let inkletAccessibilityDidBecomeTrusted = Notification.Name("InkletAccessibilityDidBecomeTrusted")
    static let inkletDidCompleteOnboarding = Notification.Name("InkletDidCompleteOnboarding")
}

private extension PromptMode {
    static let builtInIDs: Set<String> = [
        PromptMode.translateToEnglishID,
        PromptMode.chineseSummaryID,
        PromptMode.voiceCleanupID
    ]
}

private extension SelectionTranslationLanguage {
    var localizedDisplayName: String {
        switch self {
        case .followInterfaceLanguage: L10n.text("selection.language.followInterface")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .portuguese: "Português"
        case .italian: "Italiano"
        }
    }
}

private extension SelectionForceSelectionMode {
    var localizedDisplayName: String {
        switch self {
        case .disabled: L10n.text("settings.forceSelection.disabled")
        case .menuCopyOnly: L10n.text("settings.forceSelection.menuCopyOnly")
        case .menuCopyThenShortcut: L10n.text("settings.forceSelection.menuCopyThenShortcut")
        case .shortcutThenMenuCopy: L10n.text("settings.forceSelection.shortcutThenMenuCopy")
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case writeAssistant = "Write Assistant"
    case selectionAssistant = "Selection Assistant"
    case history = "History"
    case promptModes = "Prompt Modes"
    case about = "About"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.text("settings.section.general")
        case .writeAssistant: L10n.text("settings.section.writeAssistant")
        case .selectionAssistant: L10n.text("settings.section.selectionAssistant")
        case .history: L10n.text("settings.section.history")
        case .promptModes: L10n.text("settings.section.promptModes")
        case .about: L10n.text("settings.section.about")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .writeAssistant: "pencil.and.scribble"
        case .selectionAssistant: "text.viewfinder"
        case .history: "clock.arrow.circlepath"
        case .promptModes: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var migrationPresentationModel: LegacyMigrationPresentationModel
    @State private var selectedSection: SettingsSection
    @State private var promptModePendingDeletionID: String?
    @State private var isConfirmingClearHistory = false
    @State private var copiedHistoryControlID: String?
    @State private var historyCopyFeedbackTask: Task<Void, Never>?
    private let onAppearanceChange: (AppAppearance) -> Void
    private let onRequestMigrationImport: () -> Void
    private let onRetryMigrationRelaunch: () -> Void
    private let onQuitForMigration: () -> Void

    init(
        model: SettingsViewModel,
        migrationPresentationModel: LegacyMigrationPresentationModel,
        initialSection: SettingsSection = .general,
        onAppearanceChange: @escaping (AppAppearance) -> Void = { _ in },
        onRequestMigrationImport: @escaping () -> Void = {},
        onRetryMigrationRelaunch: @escaping () -> Void = {},
        onQuitForMigration: @escaping () -> Void = {}
    ) {
        self.model = model
        self.migrationPresentationModel = migrationPresentationModel
        _selectedSection = State(initialValue: initialSection)
        self.onAppearanceChange = onAppearanceChange
        self.onRequestMigrationImport = onRequestMigrationImport
        self.onRetryMigrationRelaunch = onRetryMigrationRelaunch
        self.onQuitForMigration = onQuitForMigration
    }

    private var isSuccessMessage: Bool {
        model.message == L10n.text("settings.saved") || model.message == L10n.text("settings.history.cleared")
    }

    private var pronunciationSpeedBinding: Binding<Double> {
        Binding(
            get: { model.config.selectionActions.pronunciationSpeed },
            set: {
                model.config.selectionActions.pronunciationSpeed = SelectionActionsConfig.clampedPronunciationSpeed($0)
            }
        )
    }

    private var pronunciationSpeedText: String {
        L10n.format("settings.aiPronunciation.speedValue", model.config.selectionActions.pronunciationSpeed)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
        }
        .frame(width: 860, height: 560)
        .background(InkletTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(InkletTheme.strongBorder)
        }
        .shadow(color: .black.opacity(0.75), radius: 48, x: 0, y: 28)
        .task {
            await model.refreshModelCatalogIfNeeded()
        }
        .onAppear {
            model.refreshPermissions()
            model.refreshMicrophoneOptions()
        }
        .onChange(of: model.config.appearance) {
            onAppearanceChange(model.config.appearance)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .alert(
            L10n.text("settings.mode.deleteConfirmTitle"),
            isPresented: Binding(
                get: { promptModePendingDeletionID != nil },
                set: { isPresented in
                    if !isPresented {
                        promptModePendingDeletionID = nil
                    }
                }
            )
        ) {
            Button(L10n.text("settings.mode.delete"), role: .destructive) {
                if let promptModePendingDeletionID {
                    model.deletePromptMode(modeID: promptModePendingDeletionID)
                }
                promptModePendingDeletionID = nil
            }
            Button(L10n.text("settings.cancel"), role: .cancel) {
                promptModePendingDeletionID = nil
            }
        } message: {
            Text(L10n.format("settings.mode.deleteConfirmMessage", model.promptModeName(modeID: promptModePendingDeletionID ?? "")))
        }
        .alert(
            L10n.text("settings.history.clearConfirmTitle"),
            isPresented: $isConfirmingClearHistory
        ) {
            Button(L10n.text("settings.history.clear"), role: .destructive) {
                model.clearHistory()
            }
            Button(L10n.text("settings.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("settings.history.clearConfirmMessage"))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    PenNibShape()
                        .stroke(style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(InkletTheme.primary)
                        .padding(6)
                        .frame(width: 28, height: 28)
                        .background(InkletTheme.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(InkletTheme.primary.opacity(0.20))
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Inklet")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(InkletTheme.textPrimary)
                        Text(L10n.text("settings.sidebar.preferences"))
                            .font(.system(size: 10))
                            .foregroundStyle(InkletTheme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: section.icon)
                                .frame(width: 18)
                            Text(section.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                        }
                        .font(.system(size: 13, weight: selectedSection == section ? .semibold : .regular))
                        .foregroundStyle(selectedSection == section ? InkletTheme.primary.opacity(0.95) : InkletTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selectedSection == section ? InkletTheme.primary.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Spacer()
            Text(L10n.format("settings.version", BuildInfo.displayVersion))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(InkletTheme.textFaint)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 188)
        .disabled(model.isMigrationMaintenanceActive)
        .background(InkletTheme.toolbarBackground)
        .overlay(alignment: .trailing) { Rectangle().fill(InkletTheme.subtleBorder).frame(width: 1) }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider().opacity(0.12)

            Group {
                switch selectedSection {
                case .general:
                    ScrollView {
                        generalPanel
                            .padding(.horizontal, 24)
                            .padding(.vertical, 20)
                    }
                case .writeAssistant:
                    writeAssistantPanel
                        .disabled(model.isMigrationMaintenanceActive)
                case .selectionAssistant:
                    ScrollView {
                        selectionActionsPanel
                            .padding(.horizontal, 24)
                            .padding(.vertical, 20)
                    }
                    .disabled(model.isMigrationMaintenanceActive)
                case .history:
                    historyPanel
                        .disabled(model.isMigrationMaintenanceActive)
                case .promptModes:
                    promptModesPanel
                        .disabled(model.isMigrationMaintenanceActive)
                case .about:
                    ScrollView {
                        aboutPanel
                            .padding(.horizontal, 24)
                            .padding(.vertical, 20)
                    }
                    .disabled(model.isMigrationMaintenanceActive)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().opacity(0.12)
            footer
        }
    }

    private var detailHeader: some View {
        HStack {
            Text(selectedSection.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(InkletTheme.textPrimary)
            Spacer()
            Button {
                NSApp.keyWindow?.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(InkletTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.001), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 15)
    }

    private var sectionDescription: String {
        switch selectedSection {
        case .general:
            L10n.text("settings.description.general")
        case .writeAssistant:
            L10n.text("settings.description.writeAssistant")
        case .selectionAssistant:
            L10n.text("settings.description.selectionAssistant")
        case .history:
            L10n.text("settings.description.history")
        case .promptModes:
            L10n.text("settings.description.promptModes")
        case .about:
            L10n.text("settings.description.about")
        }
    }

    private var generalPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            if migrationPresentationModel.phase != .hidden {
                migrationNoticeCard
            }

            VStack(alignment: .leading, spacing: 22) {
                settingsPanel {
                    settingsRow(L10n.text("settings.row.openAIAPIKey"), help: L10n.text("settings.help.openAIAPIKey")) {
                        SecureField(LLMProviderPreset.openAI.apiKeyPlaceholder, text: $model.providerAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    settingsRow(L10n.text("settings.row.language"), help: L10n.text("settings.help.language")) {
                        Picker("", selection: $model.interfaceLanguage) {
                            ForEach(InterfaceLanguage.allCases) { language in
                                Text(language.localizedDisplayName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                    }

                    settingsRow(L10n.text("settings.row.appearance"), help: L10n.text("settings.help.appearance")) {
                        Picker("", selection: $model.config.appearance) {
                            ForEach(AppAppearance.allCases) { appearance in
                                Text(appearance.localizedDisplayName).tag(appearance)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                }

                systemPermissionsPanel
            }
            .disabled(model.isMigrationMaintenanceActive)
        }
    }

    private var migrationNoticeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(InkletTheme.warning)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("legacyMigration.notice.title"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(InkletTheme.textPrimary)
                    Text(migrationNoticeMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(InkletTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                migrationPrimaryAction
                if migrationPresentationModel.phase == .relaunchFailed {
                    Button(L10n.text("legacyMigration.action.quit"), action: onQuitForMigration)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(InkletTheme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(InkletTheme.controlFill, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(maxWidth: 580, alignment: .leading)
        .background(InkletTheme.controlFill.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(InkletTheme.subtleBorder)
        }
    }

    private var migrationNoticeMessage: String {
        switch migrationPresentationModel.phase {
        case .failed:
            switch migrationPresentationModel.failureReason {
            case .invalidSelection:
                L10n.text("legacyMigration.import.invalidSelection")
            case .partialFailure:
                L10n.text("legacyMigration.import.partialFailure")
            case .importFailed, .none:
                L10n.text("legacyMigration.import.failed")
            }
        case .relaunching:
            L10n.text("legacyMigration.import.relaunching")
        case .relaunchFailed:
            L10n.text("legacyMigration.import.relaunchFailed")
        case .hidden, .needsImport, .selecting, .importing:
            L10n.text("legacyMigration.notice.message")
        }
    }

    @ViewBuilder
    private var migrationPrimaryAction: some View {
        switch migrationPresentationModel.phase {
        case .importing, .relaunching:
            migrationActionButton(
                titleKey: migrationPresentationModel.phase == .importing
                    ? "legacyMigration.import.progress"
                    : "legacyMigration.import.relaunchProgress",
                systemImage: "square.and.arrow.down",
                showsProgress: true,
                isEnabled: false,
                action: {}
            )
        case .relaunchFailed:
            migrationActionButton(
                titleKey: "legacyMigration.action.retryRelaunch",
                systemImage: "arrow.clockwise",
                showsProgress: false,
                isEnabled: true,
                action: onRetryMigrationRelaunch
            )
        case .hidden, .needsImport, .selecting, .failed:
            migrationActionButton(
                titleKey: "legacyMigration.action.importOldData",
                systemImage: "square.and.arrow.down",
                showsProgress: false,
                isEnabled: migrationPresentationModel.canStartImport,
                action: onRequestMigrationImport
            )
        }
    }

    private func migrationActionButton(
        titleKey: String,
        systemImage: String,
        showsProgress: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(L10n.text(titleKey))
            } icon: {
                Group {
                    if showsProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                    }
                }
                .frame(width: 14, height: 14)
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 168, height: 28)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!isEnabled)
        .help(L10n.text("legacyMigration.settings.help"))
        .accessibilityLabel(L10n.text(titleKey))
    }

    private var writeAssistantControls: some View {
        let selectedModelBinding = Binding(
            get: { model.selectedModelMenuValue },
            set: { model.selectModelMenuValue($0) }
        )

        return settingsPanel {
            settingsRow(L10n.text("settings.row.hotkey"), help: L10n.text("settings.help.hotkey")) {
                HotkeyRecorderField(hotkey: $model.config.hotkey)
                    .frame(width: 220, height: 34)
            }

            settingsRow(L10n.text("settings.row.model"), help: L10n.format("settings.help.model.default", model.selectedProvider.defaultModel)) {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.selectedProviderModelOptions.isEmpty {
                        Picker("", selection: selectedModelBinding) {
                            ForEach(model.selectedProviderModelOptions, id: \.self) { modelID in
                                Text(model.modelMenuTitle(for: modelID)).tag(modelID)
                            }
                            Divider()
                            Text(L10n.text("settings.model.custom")).tag(SettingsViewModel.customModelMenuID)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                    }

                    if model.shouldShowCustomModelField {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(model.selectedProvider.defaultModel, text: $model.config.model)
                                .textFieldStyle(.roundedBorder)
                            if !model.selectedModelIsDefault {
                                Text(L10n.text("settings.model.customized"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(InkletTheme.primary)
                            }
                        }
                    }

                    if model.isRefreshingModelCatalog {
                        Text(L10n.text("settings.model.refreshing"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            settingsRow(L10n.text("settings.row.timeout"), help: L10n.text("settings.help.timeout")) {
                Stepper(value: $model.config.timeoutSeconds, in: 1...120, step: 1) {
                    Text(L10n.format("settings.seconds", Int(model.config.timeoutSeconds)))
                        .font(.body.monospacedDigit())
                }
            }
        }
    }

    private var writingSettingsPanel: some View {
        writeAssistantControls
    }

    private var writeAssistantPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsGroupTitle(
                    L10n.text("settings.group.writing"),
                    help: L10n.text("settings.group.writing.help")
                )
                writingSettingsPanel

                settingsGroupTitle(
                    L10n.text("settings.group.dictation"),
                    help: L10n.text("settings.group.dictation.help")
                )
                dictationSettingsPanel
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var dictationSettingsPanel: some View {
        let selectedMicrophoneBinding = Binding(
            get: { model.selectedMicrophoneMenuID },
            set: { model.selectedMicrophoneMenuID = $0 }
        )

        return settingsPanel {
            settingsRow(
                L10n.text("settings.row.dictationShortcut"),
                help: L10n.text("settings.help.dictationShortcut")
            ) {
                Picker("", selection: $model.config.voiceInput.shortcut) {
                    ForEach(VoiceInputConfig.Shortcut.allCases) { shortcut in
                        Text(shortcut.localizedName).tag(shortcut)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
            }

            settingsRow(L10n.text("settings.row.microphone"), help: L10n.text("settings.help.microphone")) {
                Picker("", selection: selectedMicrophoneBinding) {
                    ForEach(model.microphoneOptions) { option in
                        Text(option.localizedName).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    settingsRow(
                        L10n.text("settings.row.fallbackSpeechModel"),
                        help: L10n.text("settings.help.fallbackSpeechModel")
                    ) {
                        TextField(
                            VoiceInputConfig.defaultSpeechModel,
                            text: $model.config.voiceInput.speechModel
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, 10)
            } label: {
                Text(L10n.text("settings.group.dictationAdvanced"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(InkletTheme.textPrimary)
            }
            .tint(InkletTheme.textSecondary)
        }
    }

    private var selectionActionsPanel: some View {
        settingsPanel {
            settingsRow(
                L10n.text("settings.row.selectionActionsEnabled"),
                help: L10n.text("settings.help.selectionActionsEnabled")
            ) {
                Toggle("", isOn: $model.config.selectionActions.isEnabled)
                    .labelsHidden()
            }

            settingsRow(
                L10n.text("settings.row.forceSelectionMode"),
                help: L10n.text("settings.help.forceSelectionMode")
            ) {
                Picker("", selection: $model.config.selectionActions.forceSelectionMode) {
                    ForEach(SelectionForceSelectionMode.settingsCases) { mode in
                        Text(mode.localizedDisplayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
            }

            settingsRow(
                L10n.text("settings.row.allowSimulatedCopyFallback"),
                help: L10n.text("settings.help.allowSimulatedCopyFallback")
            ) {
                Toggle("", isOn: $model.config.selectionActions.allowsSimulatedCopyFallback)
                    .labelsHidden()
                    .disabled(model.config.selectionActions.forceSelectionMode == .disabled)
            }

            settingsRow(
                L10n.text("settings.row.translationLanguage"),
                help: L10n.text("settings.help.translationLanguage")
            ) {
                Picker("", selection: $model.config.selectionActions.translationLanguage) {
                    ForEach(SelectionTranslationLanguage.allCases) { language in
                        Text(language.localizedDisplayName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
            }

            settingsRow(
                L10n.text("settings.row.translationPrompt"),
                help: L10n.text("settings.help.translationPrompt")
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsPromptTextView(text: $model.config.selectionActions.translationPrompt)
                        .frame(height: 118)
                        .padding(10)
                        .modifier(InkletFieldModifier())
                        .accessibilityLabel(L10n.text("settings.row.translationPrompt"))

                    Button {
                        model.resetSelectionTranslationPrompt()
                    } label: {
                        Label(
                            L10n.text("settings.translationPrompt.restoreDefault"),
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(InkletTheme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(InkletTheme.controlFill, in: RoundedRectangle(cornerRadius: 7))
                    .fixedSize()
                    .help(L10n.text("settings.translationPrompt.restoreDefault"))
                    .accessibilityLabel(L10n.text("settings.translationPrompt.restoreDefault"))
                }
                .frame(maxWidth: 420, alignment: .leading)
            }

            settingsRow(
                L10n.text("settings.row.aiPronunciation"),
                help: L10n.text("settings.help.aiPronunciation")
            ) {
                HStack(spacing: 8) {
                    Picker("", selection: $model.config.selectionActions.pronunciationVoice) {
                        ForEach(SelectionPronunciationVoice.allCases) { voice in
                            Text(voice.displayName).tag(voice)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .leading)

                    Button {
                        model.previewPronunciationVoice()
                    } label: {
                        switch model.pronunciationPreviewState {
                        case .loading(let voice) where voice == model.config.selectionActions.pronunciationVoice:
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 18, height: 18)
                        case .playing(let voice) where voice == model.config.selectionActions.pronunciationVoice:
                            SpeakerWaveIcon(state: .playing, fontSize: 13, weight: .regular)
                                .frame(width: 18, height: 18)
                        default:
                            SpeakerWaveIcon(state: .idle, fontSize: 13, weight: .regular)
                                .frame(width: 18, height: 18)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.text("settings.aiPronunciation.preview"))
                    .accessibilityLabel(L10n.text("settings.aiPronunciation.preview"))
                    .disabled(model.pronunciationPreviewState?.matches(model.config.selectionActions.pronunciationVoice) == true)
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: 320, alignment: .leading)
            }

            settingsRow(
                L10n.text("settings.row.aiPronunciationSpeed"),
                help: L10n.text("settings.help.aiPronunciationSpeed")
            ) {
                HStack(spacing: 12) {
                    Slider(
                        value: pronunciationSpeedBinding,
                        in: SelectionActionsConfig.minimumPronunciationSpeed...SelectionActionsConfig.maximumPronunciationSpeed,
                        step: 0.05
                    )
                    .frame(maxWidth: 220)

                    Text(pronunciationSpeedText)
                        .font(.body.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                .frame(maxWidth: 320, alignment: .leading)
            }
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("", selection: $model.historyFilter) {
                    Text(L10n.text("settings.history.filter.all")).tag(Optional<HistorySource>.none)
                    ForEach(HistorySource.allCases) { source in
                        Text(historySourceTitle(source)).tag(Optional(source))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .labelsHidden()

                Spacer()

                Button {
                    isConfirmingClearHistory = true
                } label: {
                    Label(L10n.text("settings.history.clear"), systemImage: "trash")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InkletTheme.warning)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(InkletTheme.controlFill, in: RoundedRectangle(cornerRadius: 7))
                .disabled(model.historyItems.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            if model.filteredHistoryItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(InkletTheme.textFaint)
                    Text(L10n.text("settings.history.empty"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(InkletTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.filteredHistoryItems) { item in
                            historyRow(item)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            model.reloadHistory()
        }
        .onDisappear {
            historyCopyFeedbackTask?.cancel()
            historyCopyFeedbackTask = nil
            copiedHistoryControlID = nil
        }
    }

    private var promptModesPanel: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                PromptModeTableView(
                    modes: model.orderedPromptModes,
                    selectedModeID: $model.selectedPromptModeID,
                    canDelete: model.config.promptModes.count > 1,
                    onMove: { source, destination in
                        model.movePromptModes(from: IndexSet(integer: source), to: destination)
                    },
                    onToggleVisibility: { modeID in
                        model.togglePromptModeVisibility(modeID: modeID)
                    },
                    onDelete: { modeID in
                        promptModePendingDeletionID = modeID
                    }
                )
                .padding(.top, 10)
                .frame(maxWidth: .infinity)
                .background(InkletTheme.toolbarBackground)
                Divider().opacity(0.12)
                Button {
                    model.addPromptMode()
                } label: {
                    Label(L10n.text("settings.mode.add"), systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(InkletTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(InkletTheme.controlFill, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundStyle(InkletTheme.subtleBorder)
                        }
                }
                .buttonStyle(.plain)
                .padding(10)
                .frame(width: 236)
            }
            .frame(minWidth: 236, idealWidth: 236, maxWidth: 236, maxHeight: .infinity, alignment: .top)
            .fixedSize(horizontal: true, vertical: false)
            .clipped()
            .overlay(alignment: .trailing) { Rectangle().fill(InkletTheme.subtleBorder).frame(width: 1) }

            if let index = model.selectedPromptModeIndex {
                ScrollView {
                    promptModeDetail(index: index)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            } else {
                Text(L10n.text("settings.mode.pick"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 280)
            }
        }
    }

    private func promptModeDetail(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 11) {
                settingsRow(L10n.text("settings.row.name"), help: L10n.text("settings.help.name")) {
                    TextField(L10n.text("settings.row.name"), text: $model.config.promptModes[index].name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .modifier(InkletFieldModifier())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("settings.row.systemPrompt"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(InkletTheme.textPrimary)

                SettingsPromptTextView(text: $model.config.promptModes[index].systemPrompt)
                    .frame(height: 164)
                    .padding(10)
                    .modifier(InkletFieldModifier())
            }

            settingsToggle(
                title: L10n.text("settings.mode.visibleInMenu"),
                subtitle: L10n.text("settings.mode.visibleInMenuHelp"),
                isOn: model.promptModeVisibilityBinding(modeID: model.config.promptModes[index].id)
            )
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var systemPermissionsPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            permissionSection(title: L10n.text("settings.systemPermissions.title")) {
                permissionLine(
                    title: L10n.text("settings.permission.accessibility"),
                    description: L10n.text("settings.permission.description"),
                    isTrusted: model.isAccessibilityTrusted,
                    action: { model.openAccessibilitySettings() }
                )
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(model.permissionRefreshID)
    }

    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsAboutSummary

            permissionSection(title: L10n.text("settings.quickStart.title")) {
                quickStartShortcuts
            }

            permissionSection(title: L10n.text("settings.privacy.title")) {
                VStack(alignment: .leading, spacing: 8) {
                    privacyLine(L10n.text("settings.privacy.keychain"))
                    privacyLine(L10n.text("settings.privacy.provider"))
                    privacyLine(L10n.text("settings.privacy.voice"))
                    privacyLine(L10n.text("settings.privacy.clipboard"))
                    privacyLine(L10n.text("settings.privacy.history"))
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(model.permissionRefreshID)
    }

    private var settingsAboutSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                PenNibShape()
                    .stroke(style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(InkletTheme.primary)
                    .padding(10)
                    .frame(width: 48, height: 48)
                    .background(InkletTheme.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(InkletTheme.primary.opacity(0.20))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Inklet")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(InkletTheme.textPrimary)
                    Text(L10n.format("settings.version", BuildInfo.displayVersion))
                        .font(.system(size: 11))
                        .foregroundStyle(InkletTheme.textTertiary)
                }
            }

            Text(L10n.text("about.tagline"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(InkletTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Link(L10n.text("about.website"), destination: URL(string: "https://getinklet.app")!)
                Link(L10n.text("about.privacyPolicy"), destination: URL(string: "https://getinklet.app/privacy")!)
                Link(L10n.text("about.support"), destination: URL(string: "mailto:support@getinklet.app")!)
            }
            .font(.system(size: 12, weight: .medium))

            Text("© 2026 Inklet")
                .font(.system(size: 11))
                .foregroundStyle(InkletTheme.textTertiary)
        }
        .padding(14)
        .frame(maxWidth: 680, alignment: .leading)
        .background(InkletTheme.controlFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(InkletTheme.subtleBorder)
        }
    }

    private var quickStartShortcuts: some View {
        HStack(alignment: .top, spacing: 48) {
            VStack(alignment: .leading, spacing: 8) {
                shortcutLine(keys: [model.config.hotkey], title: L10n.text("settings.quickStart.open"), keyWidth: 102, keyAlignment: .trailing)
                shortcutLine(keys: ["⌘", "↵"], title: L10n.text("settings.quickStart.original"), keyWidth: 102, keyAlignment: .trailing)
                if model.config.voiceInput.shortcut != .disabled {
                    shortcutLine(
                        keys: voiceShortcutKeys,
                        title: L10n.text("settings.quickStart.voice.pressAndHold"),
                        keyWidth: 102,
                        keyAlignment: .trailing
                    )
                }
            }
            .frame(width: 292, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                shortcutLine(keys: ["↵"], title: L10n.text("settings.quickStart.submit"), keyWidth: 34, keyAlignment: .leading, textSpacing: 8)
                shortcutLine(keys: ["esc"], title: L10n.text("settings.quickStart.close"), keyWidth: 34, keyAlignment: .leading, textSpacing: 8)
            }
            .frame(width: 220, alignment: .leading)
        }
        .frame(width: 560, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var voiceShortcutKeys: [String] {
        [model.config.voiceInput.shortcut.localizedName]
    }

    private func permissionStatusColor(isTrusted: Bool) -> Color {
        isTrusted ? InkletTheme.primary : InkletTheme.warning
    }

    private func permissionSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(InkletTheme.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutLine(keys: [String], title: String, keyWidth: CGFloat, keyAlignment: Alignment, textSpacing: CGFloat = 14) -> some View {
        HStack(spacing: textSpacing) {
            shortcutKeys(keys)
                .frame(width: keyWidth, alignment: keyAlignment)

            shortcutTitle(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutKeys(_ keys: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Keycap(title: key)
            }
        }
    }

    private func shortcutTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(InkletTheme.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func permissionLine(
        title: String,
        description: String,
        isTrusted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let statusColor = permissionStatusColor(isTrusted: isTrusted)

        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: isTrusted ? "checkmark" : "exclamationmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 42, height: 42)
                .background(statusColor.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(InkletTheme.textPrimary)
                }

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(InkletTheme.textTertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: action) {
                Label(L10n.text("settings.permission.openShort"), systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(InkletTheme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(InkletTheme.controlFill, in: RoundedRectangle(cornerRadius: 7))
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InkletTheme.controlFill.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(InkletTheme.subtleBorder)
        }
    }

    private func privacyLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(InkletTheme.textFaint)
                .frame(width: 3, height: 3)
                .alignmentGuide(.firstTextBaseline) { context in
                    context[VerticalAlignment.center]
                }
            Text(text.replacingOccurrences(of: "• ", with: ""))
                .font(.system(size: 12))
                .foregroundStyle(InkletTheme.textSecondary)
        }
    }

    private func historyRow(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(historySourceTitle(item.source), systemImage: historySourceIcon(item.source))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(InkletTheme.textPrimary)

                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(InkletTheme.textTertiary)

                if let label = historyMetadataLabel(item) {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(InkletTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                historyCopyButton(
                    title: L10n.text("settings.history.copyResult"),
                    text: item.outputText,
                    feedbackID: "\(item.id.uuidString)-output"
                )
            }

            historyTextBlock(title: L10n.text("settings.history.original"), text: item.inputText)
            historyTextBlock(title: L10n.text("settings.history.result"), text: item.outputText)
        }
        .padding(12)
        .background(InkletTheme.controlFill.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(InkletTheme.subtleBorder)
        }
    }

    private func historyTextBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(InkletTheme.textTertiary)

            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(InkletTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 86)
        }
    }

    private func historyCopyButton(title: String, text: String, feedbackID: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedHistoryControlID = feedbackID
            historyCopyFeedbackTask?.cancel()
            historyCopyFeedbackTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                guard copiedHistoryControlID == feedbackID else { return }
                copiedHistoryControlID = nil
                historyCopyFeedbackTask = nil
            }
        } label: {
            Image(systemName: copiedHistoryControlID == feedbackID ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InkletTheme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func historySourceTitle(_ source: HistorySource) -> String {
        switch source {
        case .write:
            L10n.text("settings.history.source.write")
        case .voice:
            L10n.text("settings.history.source.voice")
        case .selection:
            L10n.text("settings.history.source.selection")
        }
    }

    private func historySourceIcon(_ source: HistorySource) -> String {
        switch source {
        case .write:
            "pencil.and.scribble"
        case .voice:
            "mic"
        case .selection:
            "text.viewfinder"
        }
    }

    private func historyMetadataLabel(_ item: HistoryItem) -> String? {
        if let targetLanguageName = item.targetLanguageName {
            return targetLanguageName
        }
        if let modeName = item.modeName {
            return modeName
        }
        return item.model
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !model.message.isEmpty {
                Label(model.message, systemImage: isSuccessMessage ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(isSuccessMessage ? InkletTheme.success : .red)
                    .lineLimit(2)
            } else {
                Text(L10n.text("settings.footer.pending"))
                    .font(.footnote)
                    .foregroundStyle(InkletTheme.textFaint)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(InkletTheme.toolbarBackground)
    }

    private func settingsPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(0)
        .frame(maxWidth: 580, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsGroupTitle(_ title: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(InkletTheme.textPrimary)
            Text(help)
                .font(.system(size: 11))
                .foregroundStyle(InkletTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 580, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsRow<Content: View>(
        _ title: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(InkletTheme.textPrimary)
                Spacer()
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if !help.isEmpty {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(InkletTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingsToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(InkletTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(InkletTheme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

private struct PromptModeTableView: NSViewRepresentable {
    let modes: [PromptMode]
    @Binding var selectedModeID: String
    let canDelete: Bool
    let onMove: (Int, Int) -> Void
    let onToggleVisibility: (String) -> Void
    let onDelete: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            modes: modes,
            selectedModeID: $selectedModeID,
            canDelete: canDelete,
            onMove: onMove,
            onToggleVisibility: onToggleVisibility,
            onDelete: onDelete
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.registerForDraggedTypes([Coordinator.dragPasteboardType])

        let scrollView = PromptModeTableScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.modes = modes
        context.coordinator.selectedModeID = $selectedModeID
        context.coordinator.canDelete = canDelete
        context.coordinator.onMove = onMove
        context.coordinator.onToggleVisibility = onToggleVisibility
        context.coordinator.onDelete = onDelete

        guard let tableView = scrollView.documentView as? NSTableView else {
            return
        }

        PromptModeTableScrollView.syncTableWidth(tableView, to: scrollView.contentView.bounds.width)

        tableView.reloadData()
        context.coordinator.syncSelection()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnIdentifier = NSUserInterfaceItemIdentifier("PromptModeColumn")
        static let rowIdentifier = NSUserInterfaceItemIdentifier("PromptModeRow")
        static let dragPasteboardType = NSPasteboard.PasteboardType("com.inklet.prompt-mode")

        var modes: [PromptMode]
        var selectedModeID: Binding<String>
        var canDelete: Bool
        var onMove: (Int, Int) -> Void
        var onToggleVisibility: (String) -> Void
        var onDelete: (String) -> Void
        weak var tableView: NSTableView?
        private var isSyncingSelection = false

        init(
            modes: [PromptMode],
            selectedModeID: Binding<String>,
            canDelete: Bool,
            onMove: @escaping (Int, Int) -> Void,
            onToggleVisibility: @escaping (String) -> Void,
            onDelete: @escaping (String) -> Void
        ) {
            self.modes = modes
            self.selectedModeID = selectedModeID
            self.canDelete = canDelete
            self.onMove = onMove
            self.onToggleVisibility = onToggleVisibility
            self.onDelete = onDelete
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            modes.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard modes.indices.contains(row) else {
                return nil
            }

            let cell = (tableView.makeView(withIdentifier: Self.rowIdentifier, owner: self) as? PromptModeTableCellView)
                ?? PromptModeTableCellView(identifier: Self.rowIdentifier)
            let mode = modes[row]
            cell.configure(
                mode: mode,
                isSelected: mode.id == selectedModeID.wrappedValue,
                canDelete: canDelete,
                target: self
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection,
                  let tableView,
                  modes.indices.contains(tableView.selectedRow)
            else {
                return
            }

            selectedModeID.wrappedValue = modes[tableView.selectedRow].id
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard modes.indices.contains(row) else {
                return nil
            }

            let item = NSPasteboardItem()
            item.setString(modes[row].id, forType: Self.dragPasteboardType)
            return item
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let draggedModeID = info.draggingPasteboard.string(forType: Self.dragPasteboardType),
                  let sourceIndex = modes.firstIndex(where: { $0.id == draggedModeID })
            else {
                return false
            }

            let destination = max(0, min(row, modes.count))
            guard sourceIndex != destination, sourceIndex + 1 != destination else {
                return false
            }

            onMove(sourceIndex, destination)
            selectedModeID.wrappedValue = draggedModeID
            return true
        }

        @MainActor
        func syncSelection() {
            guard let tableView else {
                return
            }

            isSyncingSelection = true
            defer { isSyncingSelection = false }

            if let selectedIndex = modes.firstIndex(where: { $0.id == selectedModeID.wrappedValue }) {
                tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        }

        @MainActor
        @objc func toggleVisibility(_ sender: NSButton) {
            guard let modeID = sender.identifier?.rawValue else {
                return
            }
            onToggleVisibility(modeID)
        }

        @MainActor
        @objc func deleteMode(_ sender: NSButton) {
            guard let modeID = sender.identifier?.rawValue else {
                return
            }
            onDelete(modeID)
        }
    }
}

private final class PromptModeTableScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let tableView = documentView as? NSTableView else {
            return
        }
        Self.syncTableWidth(tableView, to: contentView.bounds.width)
    }

    static func syncTableWidth(_ tableView: NSTableView, to width: CGFloat) {
        let width = max(width, 1)
        guard tableView.tableColumns.first?.width != width else {
            return
        }

        tableView.tableColumns.first?.width = width
        var frame = tableView.frame
        frame.size.width = width
        tableView.frame = frame
    }
}

private final class PromptModeTableCellView: NSTableCellView {
    private static let rowWidth: CGFloat = 190
    private let rowContainer = NSView()
    private let selectionBackground = NSView()
    private let dragHandle = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let visibilityButton = NSButton()
    private let deleteButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isCellSelected = false
    private var isModeVisible = true
    private var canDeleteMode = true

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        mode: PromptMode,
        isSelected: Bool,
        canDelete: Bool,
        target: PromptModeTableView.Coordinator
    ) {
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        isCellSelected = isSelected
        isModeVisible = mode.isVisible
        canDeleteMode = canDelete
        titleField.stringValue = mode.name.isEmpty ? L10n.text("settings.mode.untitled") : mode.localizedName
        titleField.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
        visibilityButton.image = NSImage(systemSymbolName: mode.isVisible ? "eye" : "eye.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
        visibilityButton.toolTip = mode.isVisible ? L10n.text("settings.mode.visible") : L10n.text("settings.mode.hidden")
        visibilityButton.identifier = NSUserInterfaceItemIdentifier(mode.id)
        visibilityButton.target = target
        visibilityButton.action = #selector(PromptModeTableView.Coordinator.toggleVisibility(_:))

        deleteButton.identifier = NSUserInterfaceItemIdentifier(mode.id)
        deleteButton.target = target
        deleteButton.action = #selector(PromptModeTableView.Coordinator.deleteMode(_:))
        deleteButton.isEnabled = canDelete
        deleteButton.toolTip = L10n.text("settings.mode.delete")
        applyAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyAppearance()
    }

    private func buildView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        rowContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowContainer)

        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 12
        selectionBackground.layer?.cornerCurve = .continuous
        selectionBackground.layer?.backgroundColor = NSColor.clear.cgColor
        selectionBackground.translatesAutoresizingMaskIntoConstraints = false
        rowContainer.addSubview(selectionBackground)

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        dragHandle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
        dragHandle.contentTintColor = NSColor(white: 1, alpha: 0.18)
        dragHandle.setContentHuggingPriority(.required, for: .horizontal)
        dragHandle.setContentCompressionResistancePriority(.required, for: .horizontal)
        dragHandle.toolTip = L10n.text("settings.mode.dragToSort")
        dragHandle.translatesAutoresizingMaskIntoConstraints = false

        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = NSColor(white: 0.74, alpha: 1)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        configureIconButton(visibilityButton)
        configureIconButton(deleteButton)
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
        deleteButton.contentTintColor = NSColor(white: 1, alpha: 0.32)

        rowContainer.addSubview(dragHandle)
        rowContainer.addSubview(titleField)
        rowContainer.addSubview(visibilityButton)
        rowContainer.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            rowContainer.widthAnchor.constraint(equalToConstant: Self.rowWidth),
            rowContainer.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -16),
            rowContainer.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            rowContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            selectionBackground.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor),
            selectionBackground.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor),
            selectionBackground.topAnchor.constraint(equalTo: rowContainer.topAnchor),
            selectionBackground.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 18),
            visibilityButton.widthAnchor.constraint(equalToConstant: 24),
            visibilityButton.heightAnchor.constraint(equalToConstant: 24),
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.heightAnchor.constraint(equalToConstant: 24),
            dragHandle.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor, constant: 14),
            dragHandle.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: dragHandle.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: visibilityButton.leadingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
            visibilityButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),
            visibilityButton.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor, constant: -10),
            deleteButton.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor)
        ])
    }

    private func applyAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        selectionBackground.layer?.backgroundColor = isCellSelected
            ? NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.20 : 0.14).cgColor
            : (isHovered ? NSColor.labelColor.withAlphaComponent(isDark ? 0.04 : 0.045).cgColor : NSColor.clear.cgColor)
        titleField.textColor = isCellSelected
            ? NSColor.controlAccentColor
            : (isHovered ? .labelColor : .secondaryLabelColor)
        dragHandle.contentTintColor = isHovered || isCellSelected
            ? .secondaryLabelColor
            : .tertiaryLabelColor
        visibilityButton.contentTintColor = isModeVisible
            ? .secondaryLabelColor
            : .tertiaryLabelColor
        visibilityButton.alphaValue = isHovered || isCellSelected ? 1 : 0.78
        deleteButton.contentTintColor = canDeleteMode
            ? .secondaryLabelColor
            : .tertiaryLabelColor
        deleteButton.alphaValue = isHovered || isCellSelected ? 1 : 0.64
    }

    private func configureIconButton(_ button: NSButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
}

private struct SettingsPromptTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.horizontalScrollElasticity = .none

        let textView = NSTextView()
        textView.string = text
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.text = $text
        context.coordinator.textView = textView
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor

        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, @unchecked Sendable {
        var text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
            super.init()
        }

        @MainActor
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            text.wrappedValue = textView.string
        }
    }
}

private struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var hotkey: String

    func makeCoordinator() -> Coordinator {
        Coordinator(hotkey: $hotkey)
    }

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = { context.coordinator.hotkey.wrappedValue = $0 }
        view.hotkey = hotkey
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.hotkey = hotkey
        nsView.onChange = { context.coordinator.hotkey.wrappedValue = $0 }
        nsView.updateDisplay()
    }

    final class Coordinator {
        var hotkey: Binding<String>

        init(hotkey: Binding<String>) {
            self.hotkey = hotkey
        }
    }

    final class RecorderView: NSView {
        var hotkey = ""
        var onChange: ((String) -> Void)?
        private var isRecording = false
        private let label = NSTextField(labelWithString: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.borderWidth = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .center
            label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            updateDisplay()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { true }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateDisplay()
        }

        override func mouseDown(with event: NSEvent) {
            isRecording = true
            publishRecordingState()
            window?.makeFirstResponder(self)
            updateDisplay()
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            publishRecordingState()
            updateDisplay()
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }

            if event.keyCode == UInt16(kVK_Escape) {
                isRecording = false
                publishRecordingState()
                window?.makeFirstResponder(nil)
                updateDisplay()
                return
            }

            guard let recordedHotkey = recordedHotkey(from: event) else {
                NSSound.beep()
                return
            }

            hotkey = recordedHotkey.displayString
            onChange?(hotkey)
            isRecording = false
            publishRecordingState()
            window?.makeFirstResponder(nil)
            updateDisplay()
        }

        override func flagsChanged(with event: NSEvent) {
            if isRecording {
                updateDisplay(pressedModifiers: modifierDisplayString(from: event.modifierFlags))
            } else {
                super.flagsChanged(with: event)
            }
        }

        func updateDisplay(pressedModifiers: String = "") {
            let backgroundColor = isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.controlBackgroundColor
            layer?.backgroundColor = resolvedCGColor(backgroundColor)
            layer?.borderColor = resolvedCGColor(isRecording ? .controlAccentColor : .separatorColor)
            label.textColor = isRecording ? .controlAccentColor : .labelColor
            if isRecording {
                label.stringValue = pressedModifiers.isEmpty
                    ? L10n.text("settings.hotkey.recording")
                    : "\(pressedModifiers)\(L10n.text("settings.hotkey.pressKey"))"
            } else {
                label.stringValue = hotkey.isEmpty ? L10n.text("settings.hotkey.record") : hotkey
            }
        }

        private func resolvedCGColor(_ color: NSColor) -> CGColor {
            var resolvedColor = color.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                resolvedColor = color.cgColor
            }
            return resolvedColor
        }

        private func recordedHotkey(from event: NSEvent) -> Hotkey? {
            var modifiers: Hotkey.Modifier = []
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.shift) { modifiers.insert(.shift) }

            guard !modifiers.isEmpty,
                  modifiers != [.shift],
                  Hotkey.displayName(for: UInt32(event.keyCode)) != nil
            else {
                return nil
            }

            return Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        }

        private func modifierDisplayString(from flags: NSEvent.ModifierFlags) -> String {
            var modifiers: Hotkey.Modifier = []
            let filteredFlags = flags.intersection(.deviceIndependentFlagsMask)
            if filteredFlags.contains(.command) { modifiers.insert(.command) }
            if filteredFlags.contains(.option) { modifiers.insert(.option) }
            if filteredFlags.contains(.control) { modifiers.insert(.control) }
            if filteredFlags.contains(.shift) { modifiers.insert(.shift) }
            return modifiers.displayString
        }

        private func publishRecordingState() {
            NotificationCenter.default.post(
                name: .hotkeyRecordingDidChange,
                object: nil,
                userInfo: ["isRecording": isRecording]
            )
        }
    }
}
