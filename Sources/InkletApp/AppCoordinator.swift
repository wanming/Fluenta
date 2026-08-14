import AppKit
import InkletCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}

@MainActor
private enum SelectionPronunciationReturnState: Equatable {
    case menu
    case translationResult
}

@MainActor
final class AppCoordinator: NSObject {
    private static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

    private let statusItem: NSStatusItem
    private let windowController: InkletPopoverWindowController
    private let settingsController: SettingsWindowController
    private let aboutController: AboutWindowController
    private let hotkeyManager: GlobalHotkeyManager
    private let configStore: UserDefaultsConfigStore
    private let accessibilityPermissionService: AccessibilityPermissionService
    private let voiceStatusController: VoiceStatusWindowController
    private let voiceShortcutMonitor: VoiceShortcutMonitor
    private let audioRecorder: AudioRecorder
    private let insertionService: InsertionService
    private let apiKeyStore: LocalAPIKeyStore
    private let selectionActionMonitor: SelectionActionMonitor
    private let selectionActionWindowController: SelectionActionWindowController
    private let selectedTextReader: SelectedTextReader
    private let selectionBrowserTextReader: SelectionBrowserTextReader
    private let selectionClipboardReader: SelectionClipboardReader
    private let selectionTranslationCache: JSONSelectionTranslationCache
    private let speechPlaybackService: SpeechPlaybackService
    private let historyStore: JSONLHistoryStore
    private var configObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var onboardingObserver: NSObjectProtocol?
    private var hotkeyRecordingObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var activeApplicationObserver: NSObjectProtocol?
    private var settingsShortcutMonitor: Any?
    private var lastTargetApplication: NSRunningApplication?
    private var didObserveSystemSettingsActivation = false
    private var isRecordingHotkey = false
    private var selectionActionCoordinator: SelectionActionCoordinator
    private var selectionReadTask: Task<Void, Never>?
    private var selectionTranslationTask: Task<Void, Never>?
    private var selectionTTSTask: Task<Void, Never>?
    private var selectionCopyFeedbackTask: Task<Void, Never>?
    private var currentSelectionText = ""
    private var currentTranslationText = ""
    private var selectionPronunciationReturnState = SelectionPronunciationReturnState.menu
    private var pendingSelectionSourceProcessIdentifier: pid_t?
    private var pendingSelectionSourceBundleIdentifier: String?
    private var pendingSelectionLocation: SelectionPoint?
    private var panelDismissalPolicy = SelectionPanelDismissalPolicy()
    private lazy var voiceCoordinator = makeVoiceInputCoordinator()

    override init() {
        let historyStore = JSONLHistoryStore()

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.historyStore = historyStore
        self.windowController = InkletPopoverWindowController(historyStore: historyStore)
        self.settingsController = SettingsWindowController(historyStore: historyStore)
        self.aboutController = AboutWindowController()
        self.hotkeyManager = GlobalHotkeyManager()
        self.configStore = UserDefaultsConfigStore()
        self.accessibilityPermissionService = AccessibilityPermissionService()
        self.voiceStatusController = VoiceStatusWindowController()
        self.voiceShortcutMonitor = VoiceShortcutMonitor()
        self.audioRecorder = AudioRecorder()
        self.insertionService = InsertionService()
        self.apiKeyStore = LocalAPIKeyStore()
        self.selectionActionMonitor = SelectionActionMonitor()
        self.selectionActionWindowController = SelectionActionWindowController()
        self.selectedTextReader = SelectedTextReader()
        self.selectionBrowserTextReader = SelectionBrowserTextReader()
        self.selectionClipboardReader = SelectionClipboardReader()
        self.selectionTranslationCache = JSONSelectionTranslationCache()
        self.speechPlaybackService = SpeechPlaybackService()
        self.selectionActionCoordinator = SelectionActionCoordinator(
            config: ((try? UserDefaultsConfigStore().load()) ?? AppConfig.defaultConfig()).selectionActions
        )
        super.init()

        self.windowController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        self.voiceStatusController.onCancel = { [weak self] in
            Task { @MainActor in
                await self?.voiceCoordinator.cancel()
            }
        }
        self.selectionActionMonitor.onCandidateSelection = { [weak self] point in
            Task { @MainActor in
                self?.handleSelectionActionCandidate(at: point)
            }
        }
        self.selectionActionMonitor.onCopyTrigger = {
            [weak self] point, initialPasteboardChangeCount, sourceProcessIdentifier in
            Task { @MainActor in
                self?.handleSelectionActionCopyTrigger(
                    at: point,
                    initialPasteboardChangeCount: initialPasteboardChangeCount,
                    sourceProcessIdentifier: sourceProcessIdentifier
                )
            }
        }
        self.selectionActionMonitor.onDismiss = { [weak self] reason in
            Task { @MainActor in
                guard let self else { return }
                self.handleSelectionDismissRequest(
                    reason: String(describing: reason),
                    bypassingPanelGrace: reason.bypassesPanelGrace
                )
            }
        }
        self.selectionActionWindowController.onTranslate = { [weak self] in
            Task { @MainActor in
                self?.translateCurrentSelection()
            }
        }
        self.selectionActionWindowController.onPronounce = { [weak self] in
            Task { @MainActor in
                self?.pronounceCurrentSelection()
            }
        }
        self.selectionActionWindowController.onPronounceOriginal = { [weak self] in
            Task { @MainActor in
                self?.pronounceOriginalFromTranslation()
            }
        }
        self.selectionActionWindowController.onPronounceTranslation = { [weak self] in
            Task { @MainActor in
                self?.pronounceCurrentTranslation()
            }
        }
        self.selectionActionWindowController.onCopyTranslation = { [weak self] in
            self?.copyCurrentTranslation()
        }
        self.selectionActionWindowController.onRetryTranslation = { [weak self] in
            Task { @MainActor in
                self?.translateCurrentSelection()
            }
        }
        self.selectionActionWindowController.onDismiss = { [weak self] in
            guard let self else { return }
            self.forceDismissSelectionActions(reason: "selectionPanelEscape")
        }
        self.speechPlaybackService.onFinish = { [weak self] in
            self?.restoreSelectionPronunciationReturnState()
        }
    }

    func start() {
        configureMainMenu()
        configureStatusItemIcon()
        configureStatusItemMenu()

        rememberTargetApplication(NSWorkspace.shared.frontmostApplication)
        activeApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.handleActivatedApplication(application)
            }
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .appConfigDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.isRecordingHotkey == false else {
                    return
                }
                self?.registerConfiguredHotkey()
                self?.configureVoiceInput()
                self?.configureSelectionActions()
            }
        }

        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: .inkletAccessibilityDidBecomeTrusted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.configureVoiceInput()
                self?.configureSelectionActions()
            }
        }

        onboardingObserver = NotificationCenter.default.addObserver(
            forName: .inkletDidCompleteOnboarding,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.openPopover()
            }
        }

        hotkeyRecordingObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyRecordingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isRecording = notification.userInfo?["isRecording"] as? Bool ?? false
            Task { @MainActor in
                self?.setHotkeyRecording(isRecording)
            }
        }

        languageObserver = NotificationCenter.default.addObserver(
            forName: .inkletLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.configureMainMenu()
                self?.configureStatusItemMenu()
            }
        }

        registerConfiguredHotkey()
        configureVoiceInput()
        configureSelectionActions()
        showPermissionSettingsIfNeeded()
        installSettingsShortcutMonitor()
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let accessibilityObserver {
            NotificationCenter.default.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
        if let onboardingObserver {
            NotificationCenter.default.removeObserver(onboardingObserver)
            self.onboardingObserver = nil
        }
        if let hotkeyRecordingObserver {
            NotificationCenter.default.removeObserver(hotkeyRecordingObserver)
            self.hotkeyRecordingObserver = nil
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        if let activeApplicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeApplicationObserver)
            self.activeApplicationObserver = nil
        }
        if let settingsShortcutMonitor {
            NSEvent.removeMonitor(settingsShortcutMonitor)
            self.settingsShortcutMonitor = nil
        }
        hotkeyManager.unregister()
        voiceShortcutMonitor.stop()
        selectionActionMonitor.stop()
        selectionReadTask?.cancel()
        selectionTranslationTask?.cancel()
        selectionTTSTask?.cancel()
        selectionCopyFeedbackTask?.cancel()
        speechPlaybackService.stop()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: L10n.text("app.menu.about"),
            action: #selector(openAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(
            title: L10n.text("app.menu.quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))

        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)

        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))

        let pasteAndMatchStyleItem = NSMenuItem(
            title: "Paste and Match Style",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            keyEquivalent: "v"
        )
        pasteAndMatchStyleItem.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(pasteAndMatchStyleItem)

        editMenu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func installSettingsShortcutMonitor() {
        guard settingsShortcutMonitor == nil else {
            return
        }

        settingsShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 43, modifiers == .command else {
                return event
            }

            Task { @MainActor in
                self?.openSettings()
            }
            return nil
        }
    }

    private func rememberTargetApplication(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != NSRunningApplication.current.processIdentifier
        else {
            return
        }

        lastTargetApplication = application
    }

    private func handleActivatedApplication(_ application: NSRunningApplication?) {
        if application?.bundleIdentifier == Self.systemSettingsBundleIdentifier {
            didObserveSystemSettingsActivation = true
            return
        }

        rememberTargetApplication(application)
        if SelectionActivationDismissalPolicy.shouldDismiss(
            activatedProcessIdentifier: application?.processIdentifier,
            currentProcessIdentifier: NSRunningApplication.current.processIdentifier
        ) {
            SelectionActionDiagnostics.log(
                "activated external app dismiss pid=\(application?.processIdentifier ?? -1)"
            )
            handleSelectionDismissRequest(reason: "externalActivation", bypassingPanelGrace: true)
        } else {
            SelectionActionDiagnostics.log("activated current app ignored for selection dismiss")
        }
        refreshVoiceShortcutAfterReturningFromSystemSettingsIfNeeded()
    }

    private func refreshVoiceShortcutAfterReturningFromSystemSettingsIfNeeded() {
        guard didObserveSystemSettingsActivation else {
            return
        }

        didObserveSystemSettingsActivation = false
        guard accessibilityPermissionService.isTrusted else {
            voiceShortcutMonitor.stop()
            return
        }

        configureVoiceInput()
    }

    private func registerConfiguredHotkey() {
        guard !isRecordingHotkey else {
            return
        }

        do {
            let config = try configStore.load()
            let hotkey: Hotkey
            do {
                hotkey = try Hotkey.parse(config.hotkey)
            } catch {
                NSLog("Unsupported configured hotkey, falling back to Option+Space: \(String(describing: error))")
                hotkey = Hotkey(keyCode: 49, modifiers: [.option])
            }

            try hotkeyManager.register(hotkey) { [weak self] in
                Task { @MainActor in
                    self?.openPopover()
                }
            }
        } catch {
            NSLog("Failed to register configured hotkey: \(String(describing: error))")
        }
    }

    private func configureVoiceInput() {
        guard OnboardingPolicy.shouldConfigureVoiceShortcutMonitoring(
            isAccessibilityTrusted: accessibilityPermissionService.isTrusted
        ) else {
            voiceShortcutMonitor.stop()
            return
        }

        do {
            let config = try configStore.load()
            voiceShortcutMonitor.update(
                shortcut: config.voiceInput.shortcut,
                recordingMode: config.voiceInput.recordingMode,
                onToggle: { [weak self] in
                    Task { @MainActor in
                        await self?.voiceCoordinator.toggle()
                    }
                },
                onStart: { [weak self] in
                    Task { @MainActor in
                        await self?.voiceCoordinator.start()
                    }
                },
                onStop: { [weak self] in
                    Task { @MainActor in
                        await self?.voiceCoordinator.stop()
                    }
                },
                onCancel: { [weak self] in
                    Task { @MainActor in
                        await self?.voiceCoordinator.cancel()
                    }
                }
            )
        } catch {
            NSLog("Failed to configure voice input: \(String(describing: error))")
        }
    }

    private func configureSelectionActions() {
        let config = (try? configStore.load()) ?? AppConfig.defaultConfig()
        handleSelectionActionEffects(selectionActionCoordinator.handle(.updateConfig(config.selectionActions)))
        let isAccessibilityTrusted = accessibilityPermissionService.isTrusted
        SelectionActionDiagnostics.log(
            "configure enabled=\(config.selectionActions.isEnabled) accessibilityTrusted=\(isAccessibilityTrusted)"
        )
        if config.selectionActions.isEnabled, isAccessibilityTrusted {
            selectionActionMonitor.start()
        } else {
            selectionActionMonitor.stop()
        }
    }

    private func handleSelectionActionCandidate(at point: SelectionPoint) {
        guard let sourceApp = NSWorkspace.shared.frontmostApplication,
              sourceApp.processIdentifier != NSRunningApplication.current.processIdentifier
        else {
            return
        }

        let bundleID = sourceApp.bundleIdentifier ?? "pid-\(sourceApp.processIdentifier)"
        pendingSelectionSourceProcessIdentifier = sourceApp.processIdentifier
        pendingSelectionSourceBundleIdentifier = sourceApp.bundleIdentifier
        pendingSelectionLocation = point
        SelectionActionDiagnostics.log("candidate sourceApp=\(bundleID)")
        handleSelectionActionEffects(selectionActionCoordinator.handle(
            .candidateSelection(sourceAppBundleID: bundleID, mouseLocation: point)
        ))
    }

    private func handleSelectionActionCopyTrigger(
        at point: SelectionPoint,
        initialPasteboardChangeCount: Int,
        sourceProcessIdentifier: pid_t
    ) {
        guard sourceProcessIdentifier != NSRunningApplication.current.processIdentifier else {
            return
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            await MainActor.run {
                guard let self else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == sourceProcessIdentifier
                else {
                    SelectionActionDiagnostics.log("copy trigger source changed")
                    return
                }

                let pasteboard = NSPasteboard.general
                guard let text = SelectionCopyTriggerPolicy.validatedClipboardText(
                    initialChangeCount: initialPasteboardChangeCount,
                    currentChangeCount: pasteboard.changeCount,
                    text: pasteboard.string(forType: .string)
                ) else {
                    SelectionActionDiagnostics.log("copy trigger clipboard unchanged or empty")
                    return
                }

                SelectionActionDiagnostics.log("copy trigger showPanel")
                self.selectionActionMonitor.recordPanelShown()
                self.currentSelectionText = text
                self.currentTranslationText = ""
                self.selectionActionWindowController.showMenu(at: point)
            }
        }
    }

    private func handleSelectionActionEffects(_ effects: [SelectionActionEffect]) {
        for effect in effects {
            switch effect {
            case .scheduleRead(let delayMilliseconds):
                SelectionActionDiagnostics.log("effect scheduleRead delayMs=\(delayMilliseconds)")
                selectionReadTask?.cancel()
                selectionReadTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.completeScheduledSelectionRead()
                }
            case .cancelRead:
                SelectionActionDiagnostics.log("effect cancelRead")
                selectionReadTask?.cancel()
                selectionReadTask = nil
                pendingSelectionSourceProcessIdentifier = nil
                pendingSelectionSourceBundleIdentifier = nil
                pendingSelectionLocation = nil
            case .hidePanel:
                SelectionActionDiagnostics.log("effect hidePanel")
                selectionActionWindowController.hidePanel()
            case .cancelWork:
                SelectionActionDiagnostics.log("effect cancelWork")
                selectionTranslationTask?.cancel()
                selectionTTSTask?.cancel()
                selectionCopyFeedbackTask?.cancel()
                speechPlaybackService.stop()
            case .showPanel(let text, let location):
                SelectionActionDiagnostics.log("effect showPanel length=\(text.count)")
                panelDismissalPolicy.recordPanelShown(at: Date().timeIntervalSinceReferenceDate)
                selectionActionMonitor.recordPanelShown()
                pendingSelectionSourceProcessIdentifier = nil
                pendingSelectionSourceBundleIdentifier = nil
                pendingSelectionLocation = nil
                currentSelectionText = text
                currentTranslationText = ""
                selectionPronunciationReturnState = .menu
                selectionCopyFeedbackTask?.cancel()
                selectionActionWindowController.showMenu(at: location)
            case .showUnsupportedNotice:
                SelectionActionDiagnostics.log("effect showUnsupportedNotice")
                panelDismissalPolicy.recordPanelShown(at: Date().timeIntervalSinceReferenceDate)
                selectionActionMonitor.recordPanelShown()
                showSelectionUnsupportedNotice()
            }
        }
    }

    private func handleSelectionDismissRequest(reason: String = "unknown", bypassingPanelGrace: Bool = false) {
        guard panelDismissalPolicy.shouldDismiss(
            at: Date().timeIntervalSinceReferenceDate,
            bypassingGrace: bypassingPanelGrace
        ) else {
            SelectionActionDiagnostics.log("panel dismiss suppressed during visibility grace reason=\(reason)")
            return
        }

        forceDismissSelectionActions(reason: reason)
    }

    private func forceDismissSelectionActions(reason: String = "force") {
        SelectionActionDiagnostics.log("force dismiss selection actions reason=\(reason)")
        handleSelectionActionEffects(selectionActionCoordinator.handle(.dismiss))
    }

    private func diagnosticSummary(for result: SelectedTextReadResult) -> String {
        switch result {
        case .success(let text):
            "success length=\(text.count)"
        case .permissionDenied:
            "permissionDenied"
        case .emptySelection:
            "emptySelection"
        case .unsupported:
            "unsupported"
        case .missingFocusedElement:
            "missingFocusedElement"
        case .failed(let message):
            "failed \(message)"
        }
    }

    private func completeScheduledSelectionRead() async {
        let result = await readSelectedTextForAutomaticSelection()
        SelectionActionDiagnostics.log("read result \(diagnosticSummary(for: result))")
        handleSelectionActionEffects(selectionActionCoordinator.handle(.readCompleted(result)))
    }

    private func readSelectedTextForAutomaticSelection() async -> SelectedTextReadResult {
        let sourceProcessIdentifier = pendingSelectionSourceProcessIdentifier
        guard selectedTextReader.isFocusedSelectableTextElement(
            sourceProcessIdentifier: sourceProcessIdentifier
        ) else {
            SelectionActionDiagnostics.log("focused element is not selectable text")
            return .emptySelection
        }

        let accessibilityResult = selectedTextReader.readSelectedText(
            sourceProcessIdentifier: pendingSelectionSourceProcessIdentifier,
            mouseLocation: pendingSelectionLocation
        )
        if case .success = accessibilityResult {
            return accessibilityResult
        }
        if accessibilityResult == .permissionDenied {
            return accessibilityResult
        }

        let browserResult = await selectionBrowserTextReader.readSelectedText(
            bundleIdentifier: pendingSelectionSourceBundleIdentifier
        )
        if case .success = browserResult {
            SelectionActionDiagnostics.log("browser selection fallback success")
            return browserResult
        }

        let config = (try? configStore.load()) ?? AppConfig.defaultConfig()
        if config.selectionActions.forceSelectionMode != .disabled,
           !config.selectionActions.allowsSimulatedCopyFallback {
            let bundleID = pendingSelectionSourceBundleIdentifier
                ?? sourceProcessIdentifier.map { "pid-\($0)" }
                ?? "unknown"
            SelectionActionDiagnostics.log("simulated copy skipped sourceApp=\(bundleID)")
        }
        let clipboardResult = await selectionClipboardReader.readSelectedText(
            sourceProcessIdentifier: sourceProcessIdentifier,
            forceSelectionMode: config.selectionActions.forceSelectionMode,
            allowsSimulatedCopyFallback: config.selectionActions.allowsSimulatedCopyFallback
        )
        if case .success = clipboardResult {
            SelectionActionDiagnostics.log("force selection fallback success")
            return clipboardResult
        }

        return preferredSelectionReadResult(
            accessibilityResult: accessibilityResult,
            browserResult: browserResult,
            clipboardResult: clipboardResult
        )
    }

    private func preferredSelectionReadResult(
        accessibilityResult: SelectedTextReadResult,
        browserResult: SelectedTextReadResult,
        clipboardResult: SelectedTextReadResult
    ) -> SelectedTextReadResult {
        if clipboardResult == .emptySelection || browserResult == .emptySelection {
            return .emptySelection
        }
        if case .failed = clipboardResult {
            return clipboardResult
        }
        if case .failed = browserResult {
            return browserResult
        }
        return accessibilityResult
    }

    private func showSelectionUnsupportedNotice() {
        let point = SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
        currentSelectionText = ""
        currentTranslationText = ""
        selectionActionWindowController.showNotice(L10n.text("selection.action.unsupportedMessage"), at: point)
    }

    private func translateCurrentSelection() {
        let sourceText = currentSelectionText
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        selectionTranslationTask?.cancel()
        selectionActionWindowController.showTranslating()
        selectionTranslationTask = Task { [weak self] in
            do {
                guard let self else { return }
                let config = try self.configStore.load()
                let providerPreset = config.resolvedProviderPreset
                let providerID = config.providerID
                let apiKeyStore = self.apiKeyStore
                let provider = LLMProviderFactory.provider(for: providerPreset) {
                    guard let apiKey = apiKeyStore.loadAPIKey(forProviderID: providerID),
                          !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        throw TransformationError.provider(L10n.format("popover.error.missingAPIKey", providerPreset.name))
                    }
                    return apiKey
                }
                let targetLanguageName = config.selectionActions.translationLanguage.resolvedPromptTargetName(
                    interfaceLanguageCode: L10n.resolvedLanguage.localeIdentifier
                )
                let systemPrompt = config.selectionActions.effectiveTranslationPrompt(
                    targetLanguageName: targetLanguageName
                )
                let service = CachedSelectionTranslationService(
                    service: SelectionTranslationService(provider: provider),
                    cache: selectionTranslationCache
                )
                let translated = try await service.translate(
                    sourceText: sourceText,
                    targetLanguageName: targetLanguageName,
                    systemPrompt: systemPrompt,
                    model: config.model,
                    providerID: providerID,
                    timeoutSeconds: config.timeoutSeconds
                )
                try? self.historyStore.append(HistoryItem(
                    source: .selection,
                    inputText: sourceText,
                    outputText: translated,
                    modeName: nil,
                    targetLanguageName: targetLanguageName,
                    model: config.model,
                    metadata: ["providerID": providerID]
                ))
                await MainActor.run {
                    self.currentTranslationText = translated
                    self.selectionActionWindowController.showTranslation(translated)
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self?.selectionActionWindowController.showTranslationError(L10n.text("selection.action.translationFailed"))
                }
            }
        }
    }

    private func pronounceCurrentSelection() {
        pronounceSelectionText(currentSelectionText, returnState: .menu)
    }

    private func pronounceOriginalFromTranslation() {
        pronounceSelectionText(
            currentSelectionText,
            returnState: .translationResult,
            loadingFeedback: .loadingOriginalPronunciation,
            playingFeedback: .playingOriginalPronunciation
        )
    }

    private func pronounceCurrentTranslation() {
        pronounceSelectionText(
            currentTranslationText,
            returnState: .translationResult,
            loadingFeedback: .loadingTranslationPronunciation,
            playingFeedback: .playingTranslationPronunciation
        )
    }

    private func pronounceSelectionText(
        _ text: String,
        returnState: SelectionPronunciationReturnState,
        loadingFeedback: SelectionActionFeedback? = nil,
        playingFeedback: SelectionActionFeedback? = nil
    ) {
        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }

        selectionPronunciationReturnState = returnState
        selectionTTSTask?.cancel()
        if returnState == .translationResult, !currentTranslationText.isEmpty {
            selectionActionWindowController.showTranslation(currentTranslationText, feedback: loadingFeedback)
        } else {
            selectionActionWindowController.showPreparingPronunciation()
        }
        selectionTTSTask = Task { [weak self] in
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
                let config = (try? self.configStore.load()) ?? AppConfig.defaultConfig()
                let audioData = try await provider.speechAudio(OpenAITTSRequest(
                    input: sourceText,
                    voice: config.selectionActions.pronunciationVoice.rawValue,
                    speed: config.selectionActions.pronunciationSpeed,
                    timeoutSeconds: config.timeoutSeconds
                ))
                await MainActor.run {
                    do {
                        try self.speechPlaybackService.play(audioData: audioData)
                        if returnState == .menu {
                            self.selectionActionWindowController.showPlayingPronunciation()
                        } else if !self.currentTranslationText.isEmpty {
                            self.selectionActionWindowController.showTranslation(
                                self.currentTranslationText,
                                feedback: playingFeedback
                            )
                        }
                    } catch {
                        self.showSelectionPronunciationError(returnState: returnState)
                    }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self?.showSelectionPronunciationError(returnState: returnState)
                }
            }
        }
    }

    private func restoreSelectionPronunciationReturnState() {
        switch selectionPronunciationReturnState {
        case .menu:
            selectionActionWindowController.restoreMenu()
        case .translationResult:
            if currentTranslationText.isEmpty {
                selectionActionWindowController.restoreMenu()
            } else {
                selectionActionWindowController.showTranslation(currentTranslationText)
            }
        }
    }

    private func showSelectionPronunciationError(returnState: SelectionPronunciationReturnState) {
        let message = L10n.text("selection.action.pronunciationFailed")
        switch returnState {
        case .menu:
            selectionActionWindowController.showPronunciationError(message)
        case .translationResult:
            if currentTranslationText.isEmpty {
                selectionActionWindowController.showPronunciationError(message)
            } else {
                selectionActionWindowController.showTranslation(currentTranslationText, errorMessage: message)
            }
        }
    }

    private func copyCurrentTranslation() {
        guard !currentTranslationText.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentTranslationText, forType: .string)
        selectionCopyFeedbackTask?.cancel()
        selectionActionWindowController.showTranslation(currentTranslationText, feedback: .copiedTranslation)
        selectionCopyFeedbackTask = Task { [weak self, copiedText = currentTranslationText] in
            try? await Task.sleep(for: .milliseconds(900))
            await MainActor.run {
                guard let self, self.currentTranslationText == copiedText else { return }
                self.selectionActionWindowController.showTranslation(self.currentTranslationText)
            }
        }
    }

    private func makeVoiceInputCoordinator() -> VoiceInputCoordinator {
        VoiceInputCoordinator(
            configProvider: { [weak self] in
                ((try? self?.configStore.load()) ?? AppConfig.defaultConfig()).voiceInput
            },
            targetApplicationProvider: { [weak self] in
                self?.lastTargetApplication
            },
            startRecording: { [weak self] in
                let voiceInput = ((try? self?.configStore.load()) ?? AppConfig.defaultConfig()).voiceInput
                try await self?.audioRecorder.start(microphoneDeviceID: voiceInput.microphoneDeviceID)
            },
            stopRecording: { [weak self] in
                guard let self else {
                    throw AudioRecorder.AudioRecorderError.recordingUnavailable
                }
                return try await self.audioRecorder.stop()
            },
            cancelRecording: { [weak self] in
                await self?.audioRecorder.cancel()
            },
            transcribe: { [weak self] request in
                guard let self else {
                    throw SpeechTranscriptionError.provider(L10n.text("voice.error.recordingUnavailable"))
                }
                let config = try self.configStore.load()
                guard let endpoint = URL(string: config.voiceInput.speechEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw SpeechTranscriptionError.invalidEndpoint
                }
                defer {
                    try? FileManager.default.removeItem(at: request.audioFileURL)
                }
                let provider = OpenAISpeechTranscriptionProvider(
                    apiKeyProvider: { [apiKeyStore] in
                        guard let apiKey = apiKeyStore.loadAPIKey(forProviderID: LLMProviderPreset.openAI.id),
                              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else {
                            throw SpeechTranscriptionError.provider(L10n.text("voice.error.missingSpeechAPIKey"))
                        }
                        return apiKey
                    },
                    endpoint: endpoint
                )
                return try await provider.transcribe(request)
            },
            selectPromptMode: { [weak self] request in
                guard let self else {
                    return .cancelled
                }
                let config = (try? self.configStore.load()) ?? AppConfig.defaultConfig()
                return await self.voiceStatusController.selectPromptMode(
                    transcript: request.transcript,
                    modes: self.voicePromptModeSelectionModes(
                        for: config,
                        defaultModeID: request.defaultPromptModeID
                    ),
                    defaultModeID: request.defaultPromptModeID
                )
            },
            cleanup: { [weak self] source, modeID in
                guard let self else {
                    throw CancellationError()
                }
                let config = try self.configStore.load()
                let providerPreset = config.resolvedProviderPreset
                let providerID = config.providerID
                let apiKeyStore = self.apiKeyStore
                let provider = LLMProviderFactory.provider(for: providerPreset) {
                    guard let apiKey = apiKeyStore.loadAPIKey(forProviderID: providerID),
                          !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        throw TransformationError.provider(L10n.format("popover.error.missingAPIKey", providerPreset.name))
                    }
                    return apiKey
                }
                let mode = config.promptModeStore.resolveForInternalUse(modeID: modeID, sourceText: source)
                let result = try await TransformationService(provider: provider).transform(
                    sourceText: source,
                    mode: mode,
                    model: config.model,
                    timeoutSeconds: config.timeoutSeconds
                )
                return result.outputText
            },
            insert: { [weak self] text, targetApplication in
                guard let self else {
                    throw CancellationError()
                }
                try await self.insertionService.insert(text: text, into: targetApplication)
            },
            recordHistory: { [weak self] event in
                guard let self else { return }
                let config = (try? self.configStore.load()) ?? AppConfig.defaultConfig()
                let modeName: String?
                if let cleanupPromptModeID = event.cleanupPromptModeID {
                    modeName = config.promptModeStore.resolveForInternalUse(
                        modeID: cleanupPromptModeID,
                        sourceText: event.transcript
                    ).localizedName
                } else {
                    modeName = nil
                }

                try? self.historyStore.append(HistoryItem(
                    source: .voice,
                    inputText: event.transcript,
                    outputText: event.finalText,
                    modeName: modeName,
                    targetLanguageName: nil,
                    model: event.cleanupPromptModeID == nil ? event.speechModel : config.model,
                    metadata: [
                        "speechModel": event.speechModel,
                        "cleanupFallback": event.cleanupFallback ? "true" : "false"
                    ]
                ))
            },
            statusHandler: { [weak self] status in
                self?.voiceShortcutMonitor.setVoiceInputActive(status.allowsCancellation)
                self?.voiceStatusController.apply(status)
            }
        )
    }

    private func voicePromptModeSelectionModes(for config: AppConfig, defaultModeID: String) -> [PromptMode] {
        var modes = config.visiblePromptModes
        let fallbackCleanupMode = PromptModeStore.defaultStore().mode(id: PromptMode.voiceCleanupID)
        if let defaultMode = config.promptModeStore.mode(id: defaultModeID) ?? fallbackCleanupMode,
           !modes.contains(where: { $0.id == defaultMode.id }) {
            modes.append(defaultMode)
        }

        if modes.isEmpty, let fallbackCleanupMode {
            modes.append(fallbackCleanupMode)
        }
        return modes
    }

    private func setHotkeyRecording(_ isRecording: Bool) {
        guard isRecordingHotkey != isRecording else {
            return
        }

        isRecordingHotkey = isRecording
        if isRecording {
            hotkeyManager.unregister()
        } else {
            registerConfiguredHotkey()
        }
    }

    private func showPermissionSettingsIfNeeded() {
        guard !accessibilityPermissionService.isTrusted else {
            return
        }

        showSettings(section: .general)
    }

    private func configureStatusItemIcon() {
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.attributedTitle = NSAttributedString()
        statusItem.button?.image = makeMenuBarIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Inklet"
        statusItem.button?.setAccessibilityLabel("Inklet")
    }

    private func makeMenuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            PenNibGeometry.paths.forEach { geometry in
                guard let firstPoint = geometry.points.first else {
                    return
                }

                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: self.menuBarPoint(from: firstPoint))
                geometry.points.dropFirst().forEach { point in
                    path.line(to: self.menuBarPoint(from: point))
                }
                if geometry.isClosed {
                    path.close()
                }
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func menuBarPoint(from point: PenNibGeometry.Point) -> NSPoint {
        let scale = 0.65
        return NSPoint(
            x: 1.7 + point.x * scale,
            y: 17.3 - point.y * scale
        )
    }

    private func configureStatusItemMenu() {
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: L10n.text("app.menu.openPopover"),
                action: #selector(openPopover),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(
            title: L10n.text("app.menu.settings"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: L10n.text("app.menu.about"),
                action: #selector(openAbout),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: L10n.text("app.menu.quit"),
                action: #selector(quit),
                keyEquivalent: "q"
            )
        )
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc func openPopover() {
        forceDismissSelectionActions(reason: "openPopover")
        windowController.show(fallbackApplication: lastTargetApplication)
    }

    @objc func openSettings() {
        forceDismissSelectionActions(reason: "openSettings")
        showSettings(section: .general)
    }

    @objc func openAbout() {
        forceDismissSelectionActions(reason: "openAbout")
        aboutController.show()
    }

    private func showSettings(section: SettingsSection) {
        windowController.hide()
        settingsController.show(section: section)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
