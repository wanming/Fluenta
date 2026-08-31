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
        let audioRecorder = AudioRecorder()
        let sourceEditorBridge = WritingSourceEditorBridge()
        let dictationCoordinator = WritingDictationCoordinator(
            configProvider: {
                ((try? configStore.load()) ?? AppConfig.defaultConfig()).voiceInput
            },
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
                      endpoint.scheme == "http" || endpoint.scheme == "https",
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
                model.setDictationPhase(phase)
                Self.postDictationPhaseAnnouncement(phase)
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

        let panel = InkletPopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: popoverWidth, height: 168),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
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
            Task { @MainActor in
                await self?.dictationCoordinator.cancel()
            }
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
        invalidateDictationContext()
        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.dictationCoordinator.cancelAndWait()
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
        let pendingContextCleanupTask = dictationContextCleanupTask
        invalidateDictationContext()
        dictationShortcutMonitor.stop()
        detachSourceEditor()
        await dictationCoordinator.cancelAndWait()
        await pendingPresentationTask?.value
        await pendingContextCleanupTask?.value
        guard presentationGeneration == generation else { return }
        window?.orderOut(nil)
    }

    func reloadDictationConfiguration() {
        let config = (try? configStore.load()) ?? AppConfig.defaultConfig()
        dictationShortcutMonitor.configure(
            shortcut: config.voiceInput.shortcut,
            isEligible: { [weak self] in
                guard let self, let window = self.window else { return false }
                let sourceEditorBridge = self.sourceEditorBridge
                let model = self.model
                return sourceEditorBridge.isEligible(in: window, model: model)
            },
            onStart: { [weak self] in
                Task { @MainActor in
                    await self?.dictationCoordinator.beginHold()
                }
            },
            onStop: { [weak self] in
                Task { @MainActor in
                    await self?.dictationCoordinator.endHold()
                }
            },
            onCancel: { [weak self] in
                self?.scheduleDictationContextCancellation()
            }
        )
        dictationShortcutMonitor.start()
        if model.route == .editor, window?.isKeyWindow == true {
            activateDictationEditorContext()
        }
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
        dictationContextCleanupTask?.cancel()
        dictationContextCleanupTask = nil
        dictationShortcutMonitor.activateEditorContext()
    }

    private func invalidateDictationContext() {
        dictationContextGeneration &+= 1
        dictationContextCleanupTask?.cancel()
        dictationContextCleanupTask = nil
        dictationShortcutMonitor.invalidateContext()
    }

    private func invalidateDictationContextAndCancel() {
        invalidateDictationContext()
        scheduleDictationContextCancellation()
    }

    private func scheduleDictationContextCancellation() {
        let generation = dictationContextGeneration
        dictationContextCleanupTask?.cancel()
        dictationContextCleanupTask = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.dictationContextGeneration == generation
            else { return }
            await self.dictationCoordinator.cancelAndWait()
            guard !Task.isCancelled,
                  self.dictationContextGeneration == generation
            else { return }
            self.dictationContextCleanupTask = nil
        }
    }

    private func cancelActiveDictationAndWait() async {
        let pendingContextCleanupTask = dictationContextCleanupTask
        invalidateDictationContext()
        await dictationCoordinator.cancelAndWait()
        await pendingContextCleanupTask?.value
    }

    private func detachSourceEditor() {
        guard let textView = sourceEditorBridge.attachedTextView else { return }
        sourceEditorBridge.detach(textView)
    }

    private static func postDictationPhaseAnnouncement(
        _ phase: WritingDictationCoordinator.Phase
    ) {
        let announcement: String?
        switch phase {
        case .idle:
            announcement = nil
        case .connecting:
            announcement = L10n.text("dictation.status.connecting")
        case .listening:
            announcement = L10n.text("dictation.accessibility.listening")
        case .recordingForFallback:
            announcement = L10n.text("dictation.accessibility.recordingFallback")
        case .finalizing:
            announcement = L10n.text("dictation.status.finalizing")
        case .recovering:
            announcement = L10n.text("dictation.status.recovering")
        case .complete:
            announcement = L10n.text("dictation.accessibility.ready")
        case .failed(let errorKey):
            announcement = L10n.text(errorKey)
        }

        guard let announcement else { return }
        NSAccessibility.post(
            element: NSApp as Any,
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
