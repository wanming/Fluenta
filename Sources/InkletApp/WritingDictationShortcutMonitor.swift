import AppKit
import InkletCore

@MainActor
protocol CancellableHold: AnyObject {
    func cancel()
}

@MainActor
private final class DispatchWorkItemHold: CancellableHold {
    private var workItem: DispatchWorkItem?

    init(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        let workItem = DispatchWorkItem { @MainActor in
            action()
        }
        self.workItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

@MainActor
final class WritingDictationShortcutMonitor {
    typealias HoldScheduler = @MainActor (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any CancellableHold
    typealias ConfiguredKeyState = @MainActor (_ keyCode: UInt16) -> Bool
    typealias LocalMonitorInstaller = @MainActor (
        _ mask: NSEvent.EventTypeMask,
        _ handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any?
    typealias LocalMonitorRemover = @MainActor (Any) -> Void

    private let holdActivationDelay: TimeInterval
    private let scheduleHold: HoldScheduler
    private let configuredKeyState: ConfiguredKeyState
    private let addLocalMonitor: LocalMonitorInstaller
    private let removeLocalMonitor: LocalMonitorRemover

    private var localMonitor: Any?
    private var shortcut: VoiceInputConfig.Shortcut = .disabled
    private var isEligible: (@MainActor () -> Bool)?
    private var onStart: (@MainActor () -> Void)?
    private var onStop: (@MainActor () -> Void)?
    private var onCancel: (@MainActor () -> Void)?
    private var modifierPressTracker = VoiceShortcutModifierPressTracker()
    private var gestureRecognizer = VoiceShortcutGestureRecognizer()
    private var pendingHold: (any CancellableHold)?
    private var pendingCandidateID: UInt = 0
    private var activeCandidateID: UInt?
    private var isEditorContextActive = false
    private var isAwaitingFreshRelease = false
    private var isHoldActive = false

    init(
        holdActivationDelay: TimeInterval = 0.08,
        scheduleHold: @escaping HoldScheduler = { delay, action in
            DispatchWorkItemHold(after: delay, action: action)
        },
        configuredKeyState: @escaping ConfiguredKeyState = { keyCode in
            switch keyCode {
            case 58, 61:
                NSEvent.modifierFlags.contains(.option)
            case 54, 55:
                NSEvent.modifierFlags.contains(.command)
            default:
                false
            }
        },
        addLocalMonitor: @escaping LocalMonitorInstaller = { mask, handler in
            NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
        },
        removeLocalMonitor: @escaping LocalMonitorRemover = { monitor in
            NSEvent.removeMonitor(monitor)
        }
    ) {
        self.holdActivationDelay = holdActivationDelay
        self.scheduleHold = scheduleHold
        self.configuredKeyState = configuredKeyState
        self.addLocalMonitor = addLocalMonitor
        self.removeLocalMonitor = removeLocalMonitor
    }

    func configure(
        shortcut: VoiceInputConfig.Shortcut,
        isEligible: @escaping @MainActor () -> Bool,
        onStart: @escaping @MainActor () -> Void,
        onStop: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        resetInteraction(cancelActiveHold: true)
        modifierPressTracker.resetForLifecycleBoundary()
        isEditorContextActive = false
        isAwaitingFreshRelease = false
        self.shortcut = shortcut
        self.isEligible = isEligible
        self.onStart = onStart
        self.onStop = onStop
        self.onCancel = onCancel
    }

    func start() {
        guard localMonitor == nil else { return }
        localMonitor = addLocalMonitor([.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let localMonitor {
            removeLocalMonitor(localMonitor)
            self.localMonitor = nil
        }
        invalidateContext()
    }

    func activateEditorContext() {
        activateEditorContext(
            modifierAlreadyDown: shortcut.keyCode.map(configuredKeyState) ?? false
        )
    }

    func activateEditorContext(modifierAlreadyDown: Bool) {
        resetInteraction(cancelActiveHold: true)
        modifierPressTracker.resetForLifecycleBoundary()
        isEditorContextActive = true
        isAwaitingFreshRelease = modifierAlreadyDown
    }

    func invalidateContext() {
        resetInteraction(cancelActiveHold: true)
        isEditorContextActive = false
        isAwaitingFreshRelease = false
    }

    @discardableResult
    func handle(_ event: NSEvent) -> NSEvent {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            interruptPendingCandidate()
        default:
            break
        }
        return event
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard isEditorContextActive,
              let expectedKeyCode = shortcut.keyCode
        else { return }

        let modifierIsDown = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(shortcut.modifierFlag)
        if isAwaitingFreshRelease {
            guard !modifierIsDown else { return }
            isAwaitingFreshRelease = false
            modifierPressTracker.resetForLifecycleBoundary()
            return
        }

        guard event.keyCode == expectedKeyCode else { return }

        switch modifierPressTracker.transition(
            keyCode: event.keyCode,
            expectedKeyCode: expectedKeyCode,
            isConfiguredModifierDown: modifierIsDown
        ) {
        case .began:
            beginCandidateIfEligible()
        case .ended:
            cancelPendingHold()
            handleActions(gestureRecognizer.pressEnded())
        case .ignored:
            break
        }
    }

    private func beginCandidateIfEligible() {
        guard isEligible?() == true else { return }

        handleActions(gestureRecognizer.pressBegan())
        schedulePendingHold()
    }

    private func schedulePendingHold() {
        cancelPendingHold()
        pendingCandidateID &+= 1
        let candidateID = pendingCandidateID
        activeCandidateID = candidateID
        pendingHold = scheduleHold(holdActivationDelay) { [weak self] in
            self?.holdDelayElapsed(for: candidateID)
        }
    }

    private func holdDelayElapsed(for candidateID: UInt) {
        guard activeCandidateID == candidateID, isEditorContextActive else { return }

        pendingHold = nil
        activeCandidateID = nil
        guard isEligible?() == true else {
            gestureRecognizer.interrupt()
            return
        }

        handleActions(gestureRecognizer.holdDelayElapsed())
    }

    private func interruptPendingCandidate() {
        guard activeCandidateID != nil else { return }
        cancelPendingHold()
        gestureRecognizer.interrupt()
    }

    private func cancelPendingHold() {
        pendingHold?.cancel()
        pendingHold = nil
        activeCandidateID = nil
    }

    private func resetInteraction(cancelActiveHold: Bool) {
        cancelPendingHold()
        modifierPressTracker.reset()
        gestureRecognizer.reset()
        guard cancelActiveHold, isHoldActive else { return }

        isHoldActive = false
        onCancel?()
    }

    private func handleActions(_ actions: [VoiceShortcutGestureAction]) {
        for action in actions {
            switch action {
            case .start:
                guard !isHoldActive else { continue }
                isHoldActive = true
                onStart?()
            case .stop:
                guard isHoldActive else { continue }
                isHoldActive = false
                onStop?()
            }
        }
    }

}

private extension VoiceInputConfig.Shortcut {
    var keyCode: UInt16? {
        switch self {
        case .rightOption:
            61
        case .rightCommand:
            54
        case .leftOption:
            58
        case .leftCommand:
            55
        case .disabled:
            nil
        }
    }

    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption, .leftOption:
            .option
        case .rightCommand, .leftCommand:
            .command
        case .disabled:
            []
        }
    }
}
