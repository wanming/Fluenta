import AppKit
import InkletCore

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
    var onCandidateSelection: ((SelectionPoint) -> Void)?
    var onCopyTrigger: ((SelectionPoint) -> Void)?
    var onDismiss: ((SelectionActionDismissReason) -> Void)?

    private var monitors: [Any] = []
    private var dismissalPolicy = SelectionDismissalPolicy()
    private var copyTriggerPolicy = SelectionCopyTriggerPolicy()
    private var dragPolicy = SelectionDragPolicy()

    func start() {
        guard monitors.isEmpty else {
            return
        }

        SelectionActionDiagnostics.log("starting global monitors")
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                let point = SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
                if event.type == .leftMouseUp {
                    switch self.dragPolicy.consumeMouseUpAction(at: point, clickCount: event.clickCount) {
                    case .candidateSelection:
                        break
                    case .dismiss:
                        SelectionActionDiagnostics.log("dismiss from mouse click")
                        self.onDismiss?(.mouseClick)
                        return
                    case .ignore:
                        return
                    }
                }

                SelectionActionDiagnostics.log("candidate mouse selection")
                self.dismissalPolicy.recordCandidate(at: Date().timeIntervalSinceReferenceDate)
                self.onCandidateSelection?(point)
            }
        } as Any)

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.shift) else {
                return
            }
            Task { @MainActor in
                SelectionActionDiagnostics.log("candidate keyboard selection")
                self?.dismissalPolicy.recordCandidate(at: Date().timeIntervalSinceReferenceDate)
                self?.onCandidateSelection?(SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y))
            }
        } as Any)

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if self.isCopyShortcut(event),
                   self.copyTriggerPolicy.recordCopy(at: Date().timeIntervalSinceReferenceDate) {
                    SelectionActionDiagnostics.log("copy trigger")
                    self.onCopyTrigger?(SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y))
                    return
                }

                guard self.dismissalPolicy.shouldDismiss(at: Date().timeIntervalSinceReferenceDate) else {
                    SelectionActionDiagnostics.log("dismiss suppressed during selection grace")
                    return
                }
                SelectionActionDiagnostics.log("dismiss from keyDown")
                self.onDismiss?(.keyboard)
            }
        } as Any)

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if event.type == .leftMouseDown {
                    self.dragPolicy.recordMouseDown(at: SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y))
                    SelectionActionDiagnostics.log("mouse down recorded for selection drag")
                    return
                }
                guard self.dismissalPolicy.shouldDismiss(at: Date().timeIntervalSinceReferenceDate) else {
                    SelectionActionDiagnostics.log("dismiss suppressed during selection grace")
                    return
                }
                SelectionActionDiagnostics.log("dismiss from \(event.type)")
                self.onDismiss?(.pointerEvent(event.type))
            }
        } as Any)
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    func recordPanelShown() {
        dismissalPolicy.recordPanelShown()
    }

    private func isCopyShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 8 && modifiers == .command
    }
}
