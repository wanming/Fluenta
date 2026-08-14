import AppKit
import InkletCore

@MainActor
final class SelectionCopyEventTap {
    struct EventFields: @unchecked Sendable {
        let type: CGEventType
        let keyCode: Int64
        let flags: CGEventFlags
        let userData: Int64
        let targetProcessIdentifier: pid_t
        let timestamp: TimeInterval
        let isRepeat: Bool
    }

    struct Trigger: Equatable, Sendable {
        let sourceProcessIdentifier: pid_t
        let point: SelectionPoint
        let timestamp: TimeInterval
    }

    typealias MouseLocationProvider = @MainActor () -> SelectionPoint
    typealias TapEnableHandler = @MainActor (CFMachPort?, Bool) -> Void
    typealias CopyTriggerHandler = @MainActor (Trigger) -> Void

    static let tapLocation: CGEventTapLocation = .cgAnnotatedSessionEventTap
    static let tapPlacement: CGEventTapPlacement = .headInsertEventTap
    static let tapOptions: CGEventTapOptions = .defaultTap
    static let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        | CGEventMask(1 << CGEventType.keyUp.rawValue)

    private let mouseLocationProvider: MouseLocationProvider
    private let tapEnableHandler: TapEnableHandler
    private var onCopyTrigger: CopyTriggerHandler?
    private var copyTriggerPolicy = SelectionCopyTriggerPolicy()
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    init(
        mouseLocationProvider: @escaping MouseLocationProvider = {
            SelectionPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
        },
        tapEnableHandler: @escaping TapEnableHandler = { eventTap, enabled in
            guard let eventTap else { return }
            CGEvent.tapEnable(tap: eventTap, enable: enabled)
        },
        onCopyTrigger: CopyTriggerHandler? = nil
    ) {
        self.mouseLocationProvider = mouseLocationProvider
        self.tapEnableHandler = tapEnableHandler
        self.onCopyTrigger = onCopyTrigger
    }

    @discardableResult
    func start(onCopyTrigger: @escaping CopyTriggerHandler) -> Bool {
        guard eventTap == nil else {
            self.onCopyTrigger = onCopyTrigger
            return true
        }

        self.onCopyTrigger = onCopyTrigger
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: Self.tapLocation,
            place: Self.tapPlacement,
            options: Self.tapOptions,
            eventsOfInterest: Self.eventMask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) else {
            self.onCopyTrigger = nil
            SelectionActionDiagnostics.log("copy event tap unavailable")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            tapEnableHandler(eventTap, false)
            CFMachPortInvalidate(eventTap)
            self.onCopyTrigger = nil
            SelectionActionDiagnostics.log("copy event tap source unavailable")
            return false
        }

        self.eventTap = eventTap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tapEnableHandler(eventTap, true)
        return true
    }

    func stop() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            tapEnableHandler(eventTap, false)
            CFMachPortInvalidate(eventTap)
        }
        eventTapSource = nil
        eventTap = nil
        onCopyTrigger = nil
        copyTriggerPolicy = SelectionCopyTriggerPolicy()
    }

    func handleEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent> {
        processEvent(type: type, fields: Self.eventFields(type: type, event: event))
        return Unmanaged.passUnretained(event)
    }

    private func processEvent(type: CGEventType, fields: EventFields) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            tapEnableHandler(eventTap, true)
        default:
            handleEventFields(fields)
        }
    }

    func handleEventFields(_ fields: EventFields) {
        guard fields.keyCode == 8 else {
            return
        }

        let isSynthetic = fields.userData == SelectionClipboardReader.syntheticCopyEventUserData
        if fields.type == .keyUp {
            copyTriggerPolicy.recordKeyUp(isInkletGenerated: isSynthetic)
            return
        }
        guard fields.type == .keyDown else { return }

        let deviceIndependentModifierMask = CGEventFlags(
            rawValue: UInt64(NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue)
        )
        let modifiers = fields.flags
            .intersection(deviceIndependentModifierMask)
            .subtracting(.maskAlphaShift)
        guard modifiers == .maskCommand else {
            return
        }

        let decision = copyTriggerPolicy.recordKeyDown(
            at: fields.timestamp,
            pasteboardChangeCount: NSPasteboard.general.changeCount,
            isRepeat: fields.isRepeat,
            isInkletGenerated: isSynthetic
        )
        guard case .triggered = decision else { return }

        onCopyTrigger?(Trigger(
            sourceProcessIdentifier: fields.targetProcessIdentifier,
            point: mouseLocationProvider(),
            timestamp: fields.timestamp
        ))
    }

    private nonisolated static func eventFields(
        type: CGEventType,
        event: CGEvent
    ) -> EventFields {
        EventFields(
            type: type,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags,
            userData: event.getIntegerValueField(.eventSourceUserData),
            targetProcessIdentifier: processIdentifier(
                from: event.getIntegerValueField(.eventTargetUnixProcessID)
            ),
            timestamp: TimeInterval(event.timestamp) / 1_000_000_000,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
    }

    private nonisolated static func processIdentifier(from rawValue: Int64) -> pid_t {
        guard rawValue >= Int64(pid_t.min), rawValue <= Int64(pid_t.max) else {
            return -1
        }
        return pid_t(rawValue)
    }

    private nonisolated static let eventTapCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let eventTap = Unmanaged<SelectionCopyEventTap>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        let fields = SelectionCopyEventTap.eventFields(type: type, event: event)
        MainActor.assumeIsolated {
            eventTap.processEvent(type: type, fields: fields)
        }
        return Unmanaged.passUnretained(event)
    }
}
