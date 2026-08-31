import AppKit
import Combine
import SwiftUI
import InkletCore

@MainActor
private final class InkletPopoverPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        guard !isComposingText else {
            super.cancelOperation(sender)
            return
        }

        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else {
            super.keyDown(with: event)
            return
        }

        guard !isComposingText else {
            super.keyDown(with: event)
            return
        }

        onEscape?()
    }

    private var isComposingText: Bool {
        guard let textInputClient = firstResponder as? NSTextInputClient else {
            return false
        }

        return textInputClient.hasMarkedText()
    }
}

@MainActor
private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    private let cornerRadius: CGFloat = 16

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureLayer()
    }

    override func layout() {
        super.layout()
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = NSColor.clear.cgColor
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }
}

@MainActor
final class InkletPopoverWindowController: NSWindowController, NSWindowDelegate {
    private struct DictationGestureToken: Equatable {
        let contextGeneration: UInt
        let gestureGeneration: UInt
    }

    private let model: InkletPopoverViewModel
    private let configStore: UserDefaultsConfigStore
    private let apiKeyStore: LocalAPIKeyStore
    private let audioRecorder: AudioRecorder
    private let sourceEditorBridge: WritingSourceEditorBridge
    private let dictationCoordinator: WritingDictationCoordinator
    private let dictationShortcutMonitor: WritingDictationShortcutMonitor
    private var previousApplication: NSRunningApplication?
    private var cancellables = Set<AnyCancellable>()
    private var presentationGeneration: UInt = 0
    private var presentationTask: Task<Void, Never>?
    private var dictationContextGeneration: UInt = 0
    private var dictationContextCleanupTask: Task<Void, Never>?
    private var dictationConfigurationGeneration: UInt = 0
    private var dictationConfigurationTask: Task<Void, Never>?
    private var dictationGestureGeneration: UInt = 0
    private var activeDictationGestureToken: DictationGestureToken?
    private var dictationGestureTask: Task<Void, Never>?
    private let dictationGestureTaskArbiter =
        WritingDictationGestureTaskArbiter<DictationGestureToken>()
    private let popoverWidth: CGFloat = 600

    var onOpenSettings: (() -> Void)? {
        get {
            model.onOpenSettings
        }
        set {
            model.onOpenSettings = newValue
        }
    }

    var onBusyChange: ((Bool) -> Void)?

    var isBusy: Bool {
        model.isBusy
    }

    init(
        historyStore: any HistoryStore = JSONLHistoryStore(),
        configStore: UserDefaultsConfigStore = UserDefaultsConfigStore(),
        apiKeyStore: LocalAPIKeyStore = LocalAPIKeyStore()
    ) {
        let model = InkletPopoverViewModel(
            configStore: configStore,
            apiKeyStore: apiKeyStore,
            historyStore: historyStore
        )
        let panel = InkletPopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 168),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let audioRecorder = AudioRecorder()
        let sourceEditorBridge = WritingSourceEditorBridge()
        let dictationCoordinator = WritingDictationCoordinator(
            configProvider: { model.currentVoiceInputConfig },
            audioCapture: audioRecorder,
            makeRealtimeClient: {
                guard let apiKey = apiKeyStore.loadAPIKey(
                    forProviderID: LLMProviderPreset.openAI.id
                )?.trimmingCharacters(in: .whitespacesAndNewlines),
                !apiKey.isEmpty
                else {
                    throw RealtimeTranscriptionError.missingAPIKey
                }
                return OpenAIRealtimeTranscriptionClient(apiKeyProvider: { apiKey })
            },
            beginTransaction: {
                sourceEditorBridge.beginTransaction(model: model)
            },
            transcribeFallback: { recordingURL, config in
                let endpointString = config.speechEndpoint.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard let endpoint = URL(string: endpointString),
                      let endpointScheme = endpoint.scheme?.lowercased(),
                      endpointScheme == "http" || endpointScheme == "https",
                      endpoint.host != nil
                else {
                    throw SpeechTranscriptionError.invalidEndpoint
                }
                guard let apiKey = apiKeyStore.loadAPIKey(
                    forProviderID: LLMProviderPreset.openAI.id
                )?.trimmingCharacters(in: .whitespacesAndNewlines),
                !apiKey.isEmpty
                else {
                    throw RealtimeTranscriptionError.missingAPIKey
                }

                let provider = OpenAISpeechTranscriptionProvider(
                    apiKeyProvider: { apiKey },
                    endpoint: endpoint
                )
                let result = try await provider.transcribe(SpeechTranscriptionRequest(
                    audioFileURL: recordingURL,
                    model: config.speechModel,
                    timeoutSeconds: 20
                ))
                return result.text
            },
            phaseHandler: { phase in
                let previousPhase = model.dictationPhase
                model.setDictationPhase(phase)
                Self.postDictationPhaseAnnouncement(
                    phase,
                    previousPhase: previousPhase,
                    in: panel
                )
            }
        )
        let dictationShortcutMonitor = WritingDictationShortcutMonitor()

        self.model = model
        self.configStore = configStore
        self.apiKeyStore = apiKeyStore
        self.audioRecorder = audioRecorder
        self.sourceEditorBridge = sourceEditorBridge
        self.dictationCoordinator = dictationCoordinator
        self.dictationShortcutMonitor = dictationShortcutMonitor

        panel.title = "Inklet"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = ClearHostingView(rootView: InkletPopoverView(
            model: model,
            onSourceTextViewAttachment: { event in
                switch event {
                case .attach(let textView):
                    sourceEditorBridge.attach(textView)
                case .detach(let textView):
                    sourceEditorBridge.detach(textView)
                }
            }
        ))

        super.init(window: panel)
        panel.delegate = self
        panel.onEscape = { [weak self] in
            self?.model.escape()
        }
        shouldCascadeWindows = false

        model.$preferredPopoverHeight
            .removeDuplicates()
            .sink { [weak self] height in
                self?.resizePopover(to: height)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            model.$isTransforming,
            model.$isInserting,
            model.$dictationPhase
        )
            .map { $0 || $1 || $2.isActive }
            .removeDuplicates()
            .sink { [weak self] isBusy in
                self?.onBusyChange?(isBusy)
            }
            .store(in: &cancellables)

        model.onHidePopover = { [weak self] in
            self?.hide()
        }
        model.onFocusPopover = { [weak self] in
            self?.focusPopover()
        }
        model.onFocusSourceInput = { [weak self] request in
            self?.focusSourceTextView(for: request)
        }
        model.onCancelDictation = { [weak self] in
            self?.scheduleDictationCancellation()
        }

        model.$popoverSession
            .map(\.route)
            .removeDuplicates()
            .sink { [weak self] route in
                self?.handleRouteChange(route)
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(fallbackApplication: NSRunningApplication? = nil) {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let targetApplication: NSRunningApplication?
        if frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier {
            targetApplication = fallbackApplication
        } else {
            targetApplication = frontmostApplication ?? fallbackApplication
        }

        let generation = advancePresentationGeneration()
        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cancelActiveDictationAndWait()
            guard !Task.isCancelled, self.presentationGeneration == generation else {
                return
            }

            self.previousApplication = targetApplication
            self.model.resetForOpen(previousApplication: targetApplication)
            self.reloadDictationConfiguration()
            self.window?.appearance = self.model.appearance.nsAppearance
            self.resizePopover(to: self.model.preferredPopoverHeight)
            self.focusPopover()
            await Task.yield()
            guard !Task.isCancelled, self.presentationGeneration == generation else {
                return
            }
            self.resizePopover(to: self.model.preferredPopoverHeight)
            self.presentationTask = nil
        }
    }

    func hide() {
        let generation = advancePresentationGeneration()
        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cancelActiveDictationAndWait()
            guard self.presentationGeneration == generation else { return }
            self.window?.orderOut(nil)
            self.presentationTask = nil
        }
    }

    func cancelForMigrationMaintenance() async {
        model.cancelForMigrationMaintenance()
        await cancelDictationAndWait()
    }

    func cancelDictationAndWait() async {
        let generation = advancePresentationGeneration()
        let pendingPresentationTask = presentationTask
        presentationTask = nil
        pendingPresentationTask?.cancel()
        dictationConfigurationGeneration &+= 1
        let pendingConfigurationTask = dictationConfigurationTask
        dictationConfigurationTask = nil
        dictationShortcutMonitor.stop()
        detachSourceEditor()
        await cancelActiveDictationAndWait()
        await pendingConfigurationTask?.value
        await pendingPresentationTask?.value
        guard presentationGeneration == generation else { return }
        window?.orderOut(nil)
    }

    func reloadDictationConfiguration() {
        dictationConfigurationGeneration &+= 1
        let generation = dictationConfigurationGeneration
        let config = model.currentVoiceInputConfig
        invalidateDictationContext()
        let pendingConfigurationTask = dictationConfigurationTask
        let pendingGestureTask = dictationGestureTask
        let task = Task { @MainActor [weak self] in
            await pendingConfigurationTask?.value
            guard let self else { return }
            await self.dictationCoordinator.cancelAndWait()
            await pendingGestureTask?.value
            await self.dictationCoordinator.cancelAndWait()
            guard self.dictationConfigurationGeneration == generation else { return }

            self.dictationShortcutMonitor.configure(
                shortcut: config.shortcut,
                isEligible: { [weak self] in
                    guard let self, let window = self.window else { return false }
                    let sourceEditorBridge = self.sourceEditorBridge
                    let model = self.model
                    return sourceEditorBridge.isEligible(in: window, model: model)
                },
                onStart: { [weak self] in
                    self?.scheduleDictationHoldStart()
                },
                onStop: { [weak self] in
                    self?.scheduleDictationHoldStop()
                },
                onCancel: { [weak self] in
                    self?.scheduleDictationCancellation()
                }
            )
            self.dictationShortcutMonitor.start()
            if self.model.route == .editor, self.window?.isKeyWindow == true {
                self.dictationShortcutMonitor.activateEditorContext()
            }
            guard self.dictationConfigurationGeneration == generation else { return }
            self.dictationConfigurationTask = nil
        }
        dictationConfigurationTask = task
        dictationGestureTask = task
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard model.route == .editor else { return }
        activateDictationEditorContext()
    }

    func windowDidResignKey(_ notification: Notification) {
        invalidateDictationContextAndCancel()
    }

    private func advancePresentationGeneration() -> UInt {
        presentationGeneration &+= 1
        return presentationGeneration
    }

    private func handleRouteChange(_ route: WritingPopoverSessionState.Route) {
        switch route {
        case .editor:
            guard window?.isKeyWindow == true else { return }
            activateDictationEditorContext()
        case .modePicker:
            invalidateDictationContextAndCancel()
        }
    }

    private func activateDictationEditorContext() {
        dictationContextGeneration &+= 1
        let generation = dictationContextGeneration
        let pendingGestureTask = dictationGestureTask
        dictationGestureTask = Task { @MainActor [weak self] in
            await pendingGestureTask?.value
            guard let self, self.dictationContextGeneration == generation else { return }
            self.dictationShortcutMonitor.activateEditorContext()
        }
    }

    private func invalidateDictationContext() {
        dictationContextGeneration &+= 1
        activeDictationGestureToken = nil
        dictationShortcutMonitor.invalidateContext()
    }

    private func invalidateDictationContextAndCancel() {
        invalidateDictationContext()
        scheduleDictationCancellation()
    }

    private func scheduleDictationHoldStart() {
        dictationGestureGeneration &+= 1
        let token = DictationGestureToken(
            contextGeneration: dictationContextGeneration,
            gestureGeneration: dictationGestureGeneration
        )
        activeDictationGestureToken = token
        let pendingGestureTask = dictationGestureTask
        dictationGestureTask = dictationGestureTaskArbiter.scheduleStart(
            token: token,
            after: pendingGestureTask,
            isCurrent: { [weak self] token in
                guard let self else { return false }
                return self.dictationContextGeneration == token.contextGeneration
                    && self.dictationGestureGeneration == token.gestureGeneration
                    && self.activeDictationGestureToken == token
            },
            begin: { [weak self] in
                await self?.dictationCoordinator.beginHold()
            }
        )
    }

    private func scheduleDictationHoldStop() {
        guard let token = activeDictationGestureToken,
              token.gestureGeneration == dictationGestureGeneration
        else { return }
        activeDictationGestureToken = nil
        let pendingGestureTask = dictationGestureTask
        dictationGestureTask = dictationGestureTaskArbiter.scheduleStop(
            token: token,
            after: pendingGestureTask,
            isContextCurrent: { [weak self] token in
                self?.dictationContextGeneration == token.contextGeneration
            },
            end: { [weak self] in
                await self?.dictationCoordinator.endHold()
            }
        )
    }

    private func scheduleDictationCancellation() {
        activeDictationGestureToken = nil
        let pendingGestureTask = dictationGestureTask
        let task = dictationGestureTaskArbiter.scheduleCancellation(
            after: pendingGestureTask,
            cancelAndWait: { [weak self] in
                await self?.dictationCoordinator.cancelAndWait()
            }
        )
        dictationContextCleanupTask = task
        dictationGestureTask = task
    }

    private func cancelActiveDictationAndWait() async {
        invalidateDictationContext()
        scheduleDictationCancellation()
        let pendingGestureTask = dictationGestureTask
        let pendingContextCleanupTask = dictationContextCleanupTask
        await pendingGestureTask?.value
        await dictationCoordinator.cancelAndWait()
        await pendingContextCleanupTask?.value
    }

    private func detachSourceEditor() {
        guard let textView = sourceEditorBridge.attachedTextView else { return }
        sourceEditorBridge.detach(textView)
    }

    private static func postDictationPhaseAnnouncement(
        _ phase: WritingDictationCoordinator.Phase,
        previousPhase: WritingDictationCoordinator.Phase,
        in panel: NSPanel
    ) {
        let announcement: String?
        switch phase {
        case .idle:
            announcement = previousPhase.isActive
                ? L10n.text("dictation.accessibility.cancelled")
                : nil
        case .connecting, .recordingForFallback:
            announcement = nil
        case .listening:
            announcement = L10n.text("dictation.accessibility.listening")
        case .finalizing:
            announcement = L10n.text("dictation.status.finalizing")
        case .recovering:
            announcement = L10n.text("dictation.status.recovering")
        case .complete:
            announcement = L10n.text("dictation.accessibility.completed")
        case .failed(let errorKey):
            announcement = L10n.text(errorKey)
        }

        guard let announcement else { return }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: announcement,
                NSAccessibility.NotificationUserInfoKey.priority:
                    NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func focusPopover() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func focusSourceTextView(
        for request: FocusRequestGeneration.Request,
        remainingRetries: Int = 2
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.model.route == .editor,
                  self.model.isCurrentSourceFocusRequest(request)
            else {
                return
            }

            guard let window = self.window,
                  window.isVisible,
                  window.isKeyWindow
            else {
                return
            }

            guard let textView = window.contentView?.descendantTextViews.first else {
                guard remainingRetries > 0 else {
                    return
                }
                self.focusSourceTextView(
                    for: request,
                    remainingRetries: remainingRetries - 1
                )
                return
            }

            guard self.model.route == .editor,
                  self.model.isCurrentSourceFocusRequest(request),
                  window.isVisible,
                  window.isKeyWindow
            else {
                return
            }

            guard window.makeFirstResponder(textView) else {
                guard remainingRetries > 0 else {
                    return
                }
                self.focusSourceTextView(
                    for: request,
                    remainingRetries: remainingRetries - 1
                )
                return
            }
            self.activateDictationEditorContext()
        }
    }

    private func resizePopover(to height: CGFloat) {
        guard let window else {
            return
        }

        let height = max(1, height)
        var frame = window.frame

        let topY = frame.maxY
        frame.size.width = popoverWidth
        frame.size.height = height
        frame.origin.y = topY - height
        window.setContentSize(NSSize(width: popoverWidth, height: height))
        window.setFrame(frame, display: true, animate: false)
        window.contentView?.frame = NSRect(x: 0, y: 0, width: popoverWidth, height: height)
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
    }
}

private extension NSView {
    var descendantTextViews: [NSTextView] {
        var textViews: [NSTextView] = []
        if let textView = self as? NSTextView {
            textViews.append(textView)
        }

        for subview in subviews {
            textViews.append(contentsOf: subview.descendantTextViews)
        }

        return textViews
    }
}
