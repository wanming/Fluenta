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
    var onCopyTrigger: ((SelectionPoint, Int, pid_t) -> Void)?
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
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                let point = SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
                if event.type == .leftMouseUp {
                    switch self.dragPolicy.consumeMouseUpAction(at: point, clickCount: event.clickCount) {
                    case .candidateSelection:
                        break
                    case .dismiss:
                        SelectionActionDiagnostics.logRateLimited("dismiss from mouse click")
                        self.onDismiss?(.mouseClick)
                        return
                    case .ignore:
                        return
                    }
                }

                SelectionActionDiagnostics.logRateLimited("candidate mouse selection")
                self.dismissalPolicy.recordCandidate(at: Date().timeIntervalSinceReferenceDate)
                self.onCandidateSelection?(point)
            }
        } as Any)

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if event.keyCode == 8 {
                    let provenance = self.copyEventProvenance(for: event)
                    self.copyTriggerPolicy.recordKeyUp(
                        isInkletGenerated: provenance.marker
                            == SelectionClipboardReader.generatedCopyEventUserData
                    )
                }

                guard modifiers.contains(.shift) else {
                    return
                }
                SelectionActionDiagnostics.logRateLimited("candidate keyboard selection")
                self.dismissalPolicy.recordCandidate(at: Date().timeIntervalSinceReferenceDate)
                self.onCandidateSelection?(SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y))
            }
        } as Any)

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if event.keyCode == 8 {
                    let provenance = self.copyEventProvenance(for: event)
                    guard modifiers == .command else {
                        self.logCopyEvent(
                            event,
                            marker: provenance.marker,
                            sourcePID: provenance.sourcePID,
                            decision: "ignoredModifiers"
                        )
                        return self.dismissIfNeededForKeyDown()
                    }

                    let decision = self.copyTriggerPolicy.recordKeyDown(
                        at: Date().timeIntervalSinceReferenceDate,
                        pasteboardChangeCount: NSPasteboard.general.changeCount,
                        isRepeat: event.isARepeat,
                        isInkletGenerated: provenance.marker
                            == SelectionClipboardReader.generatedCopyEventUserData
                    )
                    switch decision {
                    case .ignoredRepeat:
                        self.logCopyEvent(
                            event,
                            marker: provenance.marker,
                            sourcePID: provenance.sourcePID,
                            decision: "ignoredRepeat"
                        )
                    case .ignoredGenerated:
                        self.logCopyEvent(
                            event,
                            marker: provenance.marker,
                            sourcePID: provenance.sourcePID,
                            decision: "ignoredGenerated"
                        )
                    case .armed:
                        self.logCopyEvent(
                            event,
                            marker: provenance.marker,
                            sourcePID: provenance.sourcePID,
                            decision: "armed"
                        )
                    case .awaitingKeyUp:
                        self.logCopyEvent(
                            event,
                            marker: provenance.marker,
                            sourcePID: provenance.sourcePID,
                            decision: "awaitingKeyUp"
                        )
                    case .triggered(let initialPasteboardChangeCount):
                        self.logCopyEvent(
                            event,
                            marker: provenance.marker,
                            sourcePID: provenance.sourcePID,
                            decision: "triggered"
                        )
                        guard let sourceApp = NSWorkspace.shared.frontmostApplication,
                              sourceApp.processIdentifier != NSRunningApplication.current.processIdentifier
                        else {
                            return
                        }
                        self.onCopyTrigger?(
                            SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y),
                            initialPasteboardChangeCount,
                            sourceApp.processIdentifier
                        )
                    }
                    return
                }

                self.dismissIfNeededForKeyDown()
            }
        } as Any)

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if event.type == .leftMouseDown {
                    self.dragPolicy.recordMouseDown(at: SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y))
                    SelectionActionDiagnostics.logRateLimited("mouse down recorded for selection drag")
                    return
                }
                guard self.dismissalPolicy.shouldDismiss(at: Date().timeIntervalSinceReferenceDate) else {
                    SelectionActionDiagnostics.logRateLimited("dismiss suppressed during selection grace")
                    return
                }
                SelectionActionDiagnostics.logRateLimited("dismiss from \(event.type)")
                self.onDismiss?(.pointerEvent(event.type))
            }
        } as Any)
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        copyTriggerPolicy.reset()
        SelectionActionDiagnostics.resetCopyEventAggregation()
    }

    func recordPanelShown() {
        dismissalPolicy.recordPanelShown()
    }

    private func dismissIfNeededForKeyDown() {
        guard dismissalPolicy.shouldDismiss(at: Date().timeIntervalSinceReferenceDate) else {
            SelectionActionDiagnostics.logRateLimited("dismiss suppressed during selection grace")
            return
        }
        SelectionActionDiagnostics.logRateLimited("dismiss from keyDown")
        onDismiss?(.keyboard)
    }

    private func copyEventProvenance(for event: NSEvent) -> (marker: Int64, sourcePID: Int64) {
        guard let cgEvent = event.cgEvent else {
            return (0, -1)
        }
        return (
            cgEvent.getIntegerValueField(.eventSourceUserData),
            cgEvent.getIntegerValueField(.eventSourceUnixProcessID)
        )
    }

    private func logCopyEvent(
        _ event: NSEvent,
        marker: Int64,
        sourcePID: Int64,
        decision: String
    ) {
        let sourceApp = NSWorkspace.shared.frontmostApplication
        let foregroundApp = sourceApp?.bundleIdentifier
            ?? "pid-\(sourceApp?.processIdentifier ?? -1)"
        SelectionActionDiagnostics.logCopyEvent(
            foregroundApp: foregroundApp,
            keyCode: event.keyCode,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue,
            isRepeat: event.isARepeat,
            sourcePID: sourcePID,
            marker: marker,
            decision: decision
        )
    }
}
