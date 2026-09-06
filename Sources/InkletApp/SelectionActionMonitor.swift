import AppKit
import InkletCore

struct SelectionPhysicalInteractionState: Equatable, Sendable {
    let isLeftMouseButtonPressed: Bool
    let isShiftPressed: Bool

    var isActive: Bool {
        isLeftMouseButtonPressed || isShiftPressed
    }
}

private final class SelectionActionMonitorSession: @unchecked Sendable {
    private let lock = NSLock()
    private var isValid = true

    var valid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isValid
    }

    func withValidValue<Value>(_ action: () -> Value) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard isValid else { return nil }
        return action()
    }

    func invalidate() {
        lock.lock()
        isValid = false
        lock.unlock()
    }
}

@MainActor
enum SelectionActionDismissReason {
    case keyboard
    case mouseClick
    case pointerEvent(NSEvent.EventType)

    var bypassesPanelGrace: Bool {
        switch self {
        case .keyboard:
            return false
        case .mouseClick, .pointerEvent:
            return true
        }
    }
}

@MainActor
final class SelectionActionMonitor {
    typealias EventHandler = @Sendable (NSEvent) -> Void
    typealias PhysicalInteractionStateProvider = @MainActor () -> SelectionPhysicalInteractionState
    typealias MonitorRegistrar = @MainActor (
        _ mask: NSEvent.EventTypeMask,
        _ handler: @escaping EventHandler
    ) -> Any?
    typealias MonitorRemover = @MainActor (_ monitor: Any) -> Void
    typealias HandoffAction = @MainActor @Sendable () -> Void
    typealias HandoffScheduler = @Sendable (_ action: @escaping HandoffAction) -> Void
    typealias CopyEventTapStarter = @MainActor (
        _ onInteractionBegin: @escaping SelectionCopyEventTap.InteractionHandler,
        _ onInteractionEnd: @escaping SelectionCopyEventTap.InteractionHandler,
        _ onCopyTrigger: @escaping SelectionCopyEventTap.CopyTriggerHandler
    ) -> Bool
    typealias CopyEventTapStopper = @MainActor () -> Void

    var onCandidateSelection: ((SelectionPoint) -> Void)?
    var onCopyTrigger: ((SelectionCopyEventTap.Trigger) -> Void)?
    var onDismiss: ((SelectionActionDismissReason) -> Void)?
    var onInteractionStateChange: ((Bool) -> Void)?

    private var monitors: [Any] = []
    private var isStarted = false
    private var dismissalPolicy = SelectionDismissalPolicy()
    private var dragPolicy = SelectionDragPolicy()
    private let copyEventTap: SelectionCopyEventTap
    private let interactionTracker: SelectionInteractionTracker
    private let physicalInteractionStateProvider: PhysicalInteractionStateProvider
    private let monitorRegistrar: MonitorRegistrar
    private let monitorRemover: MonitorRemover
    private let handoffScheduler: HandoffScheduler
    private let copyEventTapStarter: CopyEventTapStarter
    private let copyEventTapStopper: CopyEventTapStopper
    private var currentSession: SelectionActionMonitorSession?

    var isInteractionActive: Bool {
        guard isStarted else { return false }
        return interactionTracker.isActive || physicalInteractionStateProvider().isActive
    }

    init(
        copyEventTap: SelectionCopyEventTap = SelectionCopyEventTap(),
        interactionTracker: SelectionInteractionTracker = SelectionInteractionTracker(),
        physicalInteractionStateProvider: @escaping PhysicalInteractionStateProvider = {
            SelectionPhysicalInteractionState(
                isLeftMouseButtonPressed: (NSEvent.pressedMouseButtons & 1) != 0,
                isShiftPressed: NSEvent.modifierFlags.contains(.shift)
            )
        },
        monitorRegistrar: @escaping MonitorRegistrar = { mask, handler in
            NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        },
        monitorRemover: @escaping MonitorRemover = { monitor in
            NSEvent.removeMonitor(monitor)
        },
        handoffScheduler: @escaping HandoffScheduler = { action in
            Task { @MainActor in
                action()
            }
        },
        copyEventTapStarter: CopyEventTapStarter? = nil,
        copyEventTapStopper: CopyEventTapStopper? = nil
    ) {
        self.copyEventTap = copyEventTap
        self.interactionTracker = interactionTracker
        self.physicalInteractionStateProvider = physicalInteractionStateProvider
        self.monitorRegistrar = monitorRegistrar
        self.monitorRemover = monitorRemover
        self.handoffScheduler = handoffScheduler
        self.copyEventTapStarter = copyEventTapStarter ?? { begin, end, trigger in
            copyEventTap.start(
                onInteractionBegin: begin,
                onInteractionEnd: end,
                onCopyTrigger: trigger
            )
        }
        self.copyEventTapStopper = copyEventTapStopper ?? {
            copyEventTap.stop()
        }
    }

    @discardableResult
    func start() -> Bool {
        guard !isStarted else {
            return true
        }

        SelectionActionDiagnostics.log("starting global monitors")
        let interactionTracker = self.interactionTracker
        let session = SelectionActionMonitorSession()
        let handoffScheduler = self.handoffScheduler
        guard copyEventTapStarter(
            { [weak self, session, interactionTracker] in
                guard let transition = session.withValidValue({ interactionTracker.begin(.copy) }) else {
                    return
                }
                self?.handleInteractionTransition(transition)
            },
            { [weak self, session, interactionTracker] in
                guard let transition = session.withValidValue({ interactionTracker.release(.copy) }) else {
                    return
                }
                self?.handleInteractionTransition(transition)
            },
            { [weak self, session] trigger in
                guard session.valid else { return }
                self?.onCopyTrigger?(trigger)
            }
        ) else {
            rollbackFailedStart(session: session, installedMonitors: [])
            SelectionActionDiagnostics.log("copy event monitor installation failed")
            return false
        }

        var installedMonitors: [Any] = []
        func registerMonitor(
            matching mask: NSEvent.EventTypeMask,
            handler: @escaping EventHandler
        ) -> Bool {
            guard let monitor = monitorRegistrar(mask, handler) else {
                return false
            }
            installedMonitors.append(monitor)
            return true
        }

        guard registerMonitor(matching: [.leftMouseUp], handler: { [weak self, session, interactionTracker] event in
            let point = SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
            let clickCount = event.clickCount
            guard let transitions = session.withValidValue({
                (
                    interactionTracker.enqueueHandoff(for: .mouse),
                    interactionTracker.release(.mouse)
                )
            }) else {
                return
            }
            handoffScheduler { @MainActor [weak self, session, interactionTracker] in
                guard session.valid else { return }
                self?.handleInteractionTransition(transitions.0)
                self?.handleInteractionTransition(transitions.1)
                defer {
                    if let transition = session.withValidValue({
                        interactionTracker.completeHandoff(for: .mouse)
                    }) {
                        self?.handleInteractionTransition(transition)
                    }
                }
                guard let self else { return }
                switch self.dragPolicy.consumeMouseUpAction(at: point, clickCount: clickCount) {
                case .candidateSelection:
                    break
                case .dismiss:
                    SelectionActionDiagnostics.logRateLimited("dismiss from mouse click")
                    self.onDismiss?(.mouseClick)
                    return
                case .ignore:
                    return
                }

                SelectionActionDiagnostics.logRateLimited("candidate mouse selection")
                self.dismissalPolicy.recordCandidate(at: Date().timeIntervalSinceReferenceDate)
                self.onCandidateSelection?(point)
            }
        }) else {
            return failMonitorInstallation(session: session, installedMonitors: installedMonitors)
        }

        guard registerMonitor(matching: [.keyUp], handler: { [weak self, session, interactionTracker] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.shift) else {
                return
            }
            let point = SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
            guard let enqueueTransition = session.withValidValue({
                interactionTracker.enqueueHandoff(for: .keyboard)
            }) else {
                return
            }
            handoffScheduler { @MainActor [weak self, session, interactionTracker] in
                guard session.valid else { return }
                self?.handleInteractionTransition(enqueueTransition)
                defer {
                    if let transition = session.withValidValue({
                        interactionTracker.completeHandoff(for: .keyboard)
                    }) {
                        self?.handleInteractionTransition(transition)
                    }
                }
                SelectionActionDiagnostics.logRateLimited("candidate keyboard selection")
                self?.dismissalPolicy.recordCandidate(at: Date().timeIntervalSinceReferenceDate)
                self?.onCandidateSelection?(point)
            }
        }) else {
            return failMonitorInstallation(session: session, installedMonitors: installedMonitors)
        }

        guard registerMonitor(matching: [.flagsChanged], handler: { [weak self, session, interactionTracker] event in
            guard let transition = session.withValidValue({
                if event.modifierFlags.contains(.shift) {
                    interactionTracker.begin(.keyboard)
                } else {
                    interactionTracker.release(.keyboard)
                }
            }) else {
                return
            }
            handoffScheduler { @MainActor [weak self, session] in
                guard session.valid else { return }
                self?.handleInteractionTransition(transition)
            }
        }) else {
            return failMonitorInstallation(session: session, installedMonitors: installedMonitors)
        }

        guard registerMonitor(matching: [.keyDown], handler: { [weak self, session, interactionTracker] event in
            guard !Self.isCopyShortcut(event) else {
                return
            }
            guard let enqueueTransition = session.withValidValue({
                interactionTracker.enqueueHandoff(for: .keyboard)
            }) else {
                return
            }
            handoffScheduler { @MainActor [weak self, session, interactionTracker] in
                guard session.valid else { return }
                self?.handleInteractionTransition(enqueueTransition)
                defer {
                    if let transition = session.withValidValue({
                        interactionTracker.completeHandoff(for: .keyboard)
                    }) {
                        self?.handleInteractionTransition(transition)
                    }
                }
                guard let self else { return }
                guard self.dismissalPolicy.shouldDismiss(at: Date().timeIntervalSinceReferenceDate) else {
                    SelectionActionDiagnostics.logRateLimited("dismiss suppressed during selection grace")
                    return
                }
                SelectionActionDiagnostics.logRateLimited("dismiss from keyDown")
                self.onDismiss?(.keyboard)
            }
        }) else {
            return failMonitorInstallation(session: session, installedMonitors: installedMonitors)
        }

        guard registerMonitor(
            matching: [.scrollWheel, .leftMouseDown, .rightMouseDown],
            handler: { [weak self, session, interactionTracker] event in
                let eventType = event.type
                let point = SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
                guard let transitionAndCompletion = session.withValidValue({
                    if eventType == .leftMouseDown {
                        return (interactionTracker.begin(.mouse), false)
                    }
                    return (interactionTracker.enqueueHandoff(for: .mouse), true)
                }) else {
                    return
                }
                handoffScheduler { @MainActor [weak self, session, interactionTracker] in
                    guard session.valid else { return }
                    self?.handleInteractionTransition(transitionAndCompletion.0)
                    defer {
                        if transitionAndCompletion.1,
                           let transition = session.withValidValue({
                               interactionTracker.completeHandoff(for: .mouse)
                           }) {
                            self?.handleInteractionTransition(transition)
                        }
                    }
                    guard let self else { return }
                    if eventType == .leftMouseDown {
                        self.dragPolicy.recordMouseDown(at: point)
                        SelectionActionDiagnostics.logRateLimited("mouse down recorded for selection drag")
                        return
                    }
                    guard self.dismissalPolicy.shouldDismiss(at: Date().timeIntervalSinceReferenceDate) else {
                        SelectionActionDiagnostics.logRateLimited("dismiss suppressed during selection grace")
                        return
                    }
                    SelectionActionDiagnostics.logRateLimited("dismiss from \(eventType)")
                    self.onDismiss?(.pointerEvent(eventType))
                }
            }
        ) else {
            return failMonitorInstallation(session: session, installedMonitors: installedMonitors)
        }

        monitors = installedMonitors
        currentSession = session
        isStarted = true
        let physicalState = physicalInteractionStateProvider()
        if physicalState.isLeftMouseButtonPressed,
           let transition = session.withValidValue({ interactionTracker.begin(.mouse) }) {
            handleInteractionTransition(transition)
        }
        if physicalState.isShiftPressed,
           let transition = session.withValidValue({ interactionTracker.begin(.keyboard) }) {
            handleInteractionTransition(transition)
        }
        return true
    }

    func stop() {
        currentSession?.invalidate()
        currentSession = nil
        isStarted = false
        copyEventTapStopper()
        monitors.forEach(monitorRemover)
        monitors.removeAll()
        handleInteractionTransition(interactionTracker.reset())
        SelectionActionDiagnostics.resetEventAggregation()
    }

    private func failMonitorInstallation(
        session: SelectionActionMonitorSession,
        installedMonitors: [Any]
    ) -> Bool {
        rollbackFailedStart(session: session, installedMonitors: installedMonitors)
        SelectionActionDiagnostics.log("global selection monitor installation failed")
        return false
    }

    private func rollbackFailedStart(
        session: SelectionActionMonitorSession,
        installedMonitors: [Any]
    ) {
        session.invalidate()
        currentSession = nil
        isStarted = false
        installedMonitors.forEach(monitorRemover)
        copyEventTapStopper()
        handleInteractionTransition(interactionTracker.reset())
    }

    func recordPanelShown() {
        dismissalPolicy.recordPanelShown()
    }

    private nonisolated static func isCopyShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        return event.keyCode == 8 && modifiers == .command
    }

    private func handleInteractionTransition(_ transition: SelectionInteractionTracker.Transition) {
        switch transition {
        case .unchanged:
            break
        case .becameActive:
            onInteractionStateChange?(true)
        case .becameIdle:
            onInteractionStateChange?(false)
        }
    }
}
