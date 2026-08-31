import AppKit
import XCTest
@testable import Inklet
@testable import InkletCore

@MainActor
final class WritingDictationShortcutMonitorTests: XCTestCase {
    func testShortPressDoesNotStartOrStop() {
        let harness = ShortcutMonitorHarness()
        harness.activateEditorContext()

        harness.sendModifier(keyCode: 61, flags: .option)
        harness.sendModifier(keyCode: 61, flags: [])
        harness.scheduler.fireNext()

        XCTAssertEqual(harness.actions, [])
    }

    func testHoldStartsAfterInjectedDelayAndReleaseStopsExactlyOnce() {
        let harness = ShortcutMonitorHarness()
        harness.activateEditorContext()

        harness.sendModifier(keyCode: 61, flags: .option)
        XCTAssertEqual(harness.scheduler.delays, [0.08])

        harness.scheduler.fireNext()
        XCTAssertEqual(harness.actions, [.start])

        harness.isEligible = false
        harness.sendModifier(keyCode: 61, flags: [])
        harness.sendModifier(keyCode: 61, flags: [])

        XCTAssertEqual(harness.actions, [.start, .stop])
    }

    func testEligibilityIsRecheckedWhenHoldDelayElapses() {
        let harness = ShortcutMonitorHarness()
        harness.activateEditorContext()
        harness.sendModifier(keyCode: 61, flags: .option)

        harness.isEligible = false
        harness.scheduler.fireNext()
        harness.sendModifier(keyCode: 61, flags: [])

        XCTAssertEqual(harness.actions, [])
    }

    func testModifierAlreadyDownRequiresFreshReleaseBeforeHolding() {
        let harness = ShortcutMonitorHarness()
        harness.configuredKeyIsDown = true
        harness.subject.activateEditorContext()

        let gateRelease = harness.sendModifier(keyCode: 61, flags: [])
        XCTAssertTrue(harness.actions.isEmpty)
        XCTAssertTrue(harness.scheduler.delays.isEmpty)

        let freshPress = harness.sendModifier(keyCode: 61, flags: .option)
        harness.scheduler.fireNext()
        let freshRelease = harness.sendModifier(keyCode: 61, flags: [])

        XCTAssertEqual(harness.actions, [.start, .stop])
        XCTAssertTrue(gateRelease.returned === gateRelease.sent)
        XCTAssertTrue(freshPress.returned === freshPress.sent)
        XCTAssertTrue(freshRelease.returned === freshRelease.sent)
    }

    func testFreshReleaseGateIgnoresUnrelatedAndRepeatedModifierDownEvents() {
        let harness = ShortcutMonitorHarness()
        harness.subject.activateEditorContext(modifierAlreadyDown: true)

        harness.sendModifier(keyCode: 58, flags: [])
        harness.sendModifier(keyCode: 61, flags: .option, configuredKeyIsDown: true)
        harness.scheduler.fireNext()
        harness.sendModifier(keyCode: 61, flags: .option, configuredKeyIsDown: true)
        harness.scheduler.fireNext()

        XCTAssertEqual(harness.actions, [])
        XCTAssertEqual(harness.scheduler.delays, [])

        harness.sendModifier(keyCode: 61, flags: [], configuredKeyIsDown: false)
        harness.sendModifier(keyCode: 61, flags: .option, configuredKeyIsDown: true)
        harness.scheduler.fireNext()
        harness.sendModifier(keyCode: 61, flags: [], configuredKeyIsDown: false)

        XCTAssertEqual(harness.actions, [.start, .stop])
        XCTAssertEqual(harness.scheduler.delays, [0.08])
    }

    func testRightOptionReleaseOpensGateWhileLeftOptionKeepsAggregateFlagSet() {
        let harness = ShortcutMonitorHarness(shortcut: .rightOption)
        harness.subject.activateEditorContext(modifierAlreadyDown: true)

        harness.sendModifier(keyCode: 61, flags: .option, configuredKeyIsDown: false)
        harness.sendModifier(keyCode: 61, flags: .option, configuredKeyIsDown: true)
        harness.scheduler.fireNext()
        harness.sendModifier(keyCode: 61, flags: .option, configuredKeyIsDown: false)

        XCTAssertEqual(harness.actions, [.start, .stop])
    }

    func testRightCommandReleaseOpensGateWhileLeftCommandKeepsAggregateFlagSet() {
        let harness = ShortcutMonitorHarness(shortcut: .rightCommand)
        harness.subject.activateEditorContext(modifierAlreadyDown: true)

        harness.sendModifier(keyCode: 54, flags: .command, configuredKeyIsDown: false)
        harness.sendModifier(keyCode: 54, flags: .command, configuredKeyIsDown: true)
        harness.scheduler.fireNext()
        harness.sendModifier(keyCode: 54, flags: .command, configuredKeyIsDown: false)

        XCTAssertEqual(harness.actions, [.start, .stop])
    }

    func testKeyDownInterruptsPendingCandidateWithoutConsumingEvent() {
        let harness = ShortcutMonitorHarness()
        harness.activateEditorContext()
        harness.sendModifier(keyCode: 61, flags: .option)

        let escape = harness.sendKeyDown(keyCode: 53)
        harness.scheduler.fireNext()
        harness.sendModifier(keyCode: 61, flags: [])

        XCTAssertEqual(harness.actions, [])
        XCTAssertTrue(escape.returned === escape.sent)
    }

    func testKeyDownAfterHoldStartsDoesNotCancelActiveHold() {
        let harness = ShortcutMonitorHarness()
        harness.activateEditorContext()
        harness.sendModifier(keyCode: 61, flags: .option)
        harness.scheduler.fireNext()

        harness.sendKeyDown(keyCode: 0)
        harness.sendModifier(keyCode: 61, flags: [])

        XCTAssertEqual(harness.actions, [.start, .stop])
    }

    func testInvalidatingContextCancelsActiveHoldAndSuppressesLaterRelease() {
        let harness = ShortcutMonitorHarness()
        harness.activateEditorContext()
        harness.sendModifier(keyCode: 61, flags: .option)
        harness.scheduler.fireNext()

        harness.subject.invalidateContext()
        harness.sendModifier(keyCode: 61, flags: [])

        XCTAssertEqual(harness.actions, [.start, .cancel])
    }

    func testStopCancelsActiveHoldAndSuppressesLaterRelease() {
        let harness = ShortcutMonitorHarness()
        harness.activateEditorContext()
        harness.subject.start()
        harness.sendModifier(keyCode: 61, flags: .option)
        harness.scheduler.fireNext()

        harness.subject.stop()
        harness.sendModifier(keyCode: 61, flags: [])

        XCTAssertEqual(harness.actions, [.start, .cancel])
    }

    func testRepeatedActivationCancelsPendingHoldAndRequiresReleaseWhenKeyUpWasMissing() {
        let harness = ShortcutMonitorHarness()
        harness.activateEditorContext()
        harness.sendModifier(keyCode: 61, flags: .option)

        harness.subject.activateEditorContext(modifierAlreadyDown: true)
        harness.scheduler.fireNext()
        harness.sendModifier(keyCode: 61, flags: [])

        harness.sendModifier(keyCode: 61, flags: .option)
        harness.scheduler.fireNext()
        harness.sendModifier(keyCode: 61, flags: [])

        XCTAssertEqual(harness.actions, [.start, .stop])
    }

    func testDisabledShortcutNeverStarts() {
        let harness = ShortcutMonitorHarness(shortcut: .disabled)
        harness.activateEditorContext()

        for keyCode: UInt16 in [58, 61, 54, 55] {
            harness.sendModifier(keyCode: keyCode, flags: [.option, .command])
            harness.scheduler.fireNext()
            harness.sendModifier(keyCode: keyCode, flags: [])
        }

        XCTAssertEqual(harness.actions, [])
        XCTAssertTrue(harness.scheduler.delays.isEmpty)
    }

    func testEverySupportedShortcutUsesItsPhysicalModifierKeyCode() {
        let configurations: [(VoiceInputConfig.Shortcut, UInt16, NSEvent.ModifierFlags)] = [
            (.rightOption, 61, .option),
            (.leftOption, 58, .option),
            (.rightCommand, 54, .command),
            (.leftCommand, 55, .command),
        ]

        for (shortcut, keyCode, flags) in configurations {
            let harness = ShortcutMonitorHarness(shortcut: shortcut)
            harness.activateEditorContext()

            harness.sendModifier(keyCode: keyCode, flags: flags)
            harness.scheduler.fireNext()
            harness.sendModifier(keyCode: keyCode, flags: [])

            XCTAssertEqual(harness.actions, [.start, .stop], "Failed for \(shortcut)")
        }
    }

    func testIneligibleWritingEditorStatesNeverCreateHoldCandidate() {
        let ineligibleStates = [
            "marked text",
            "mode picker route",
            "result editor focus",
            "inactive panel",
            "transformation busy",
            "dictation busy",
        ]

        for state in ineligibleStates {
            let harness = ShortcutMonitorHarness(isEligible: false)
            harness.activateEditorContext()
            harness.sendModifier(keyCode: 61, flags: .option)
            harness.scheduler.fireNext()
            harness.sendModifier(keyCode: 61, flags: [])

            XCTAssertEqual(harness.actions, [], "Unexpected action for \(state)")
            XCTAssertTrue(harness.scheduler.delays.isEmpty, "Unexpected timer for \(state)")
        }
    }

    func testStartInstallsOneLocalFlagsAndKeyMonitorAndStopRemovesIt() {
        let harness = ShortcutMonitorHarness()

        harness.subject.start()
        harness.subject.start()

        XCTAssertEqual(harness.eventMonitors.addCount, 1)
        XCTAssertEqual(harness.eventMonitors.masks, [[.flagsChanged, .keyDown]])

        let event = makeKeyEvent(type: .keyDown, keyCode: 53, flags: [])
        let returned = harness.eventMonitors.handler?(event)
        XCTAssertTrue(returned === event)

        harness.subject.stop()
        harness.subject.stop()
        XCTAssertEqual(harness.eventMonitors.removeCount, 1)

        harness.subject.start()
        harness.subject.stop()
        XCTAssertEqual(harness.eventMonitors.addCount, 2)
        XCTAssertEqual(harness.eventMonitors.removeCount, 2)
    }

    func testStoppedMonitorCanReleaseLastReferenceOffMainActor() async {
        let eventMonitors = LocalEventMonitorHarness()
        var subject: WritingDictationShortcutMonitor? = WritingDictationShortcutMonitor(
            addLocalMonitor: { mask, handler in
                eventMonitors.add(mask: mask, handler: handler)
            },
            removeLocalMonitor: { monitor in
                eventMonitors.remove(monitor)
            }
        )
        weak let weakSubject = subject

        subject?.start()
        subject?.stop()
        XCTAssertEqual(eventMonitors.removeCount, 1)

        let releaseTask = Task.detached { [subject] in
            withExtendedLifetime(subject) {}
        }
        subject = nil
        await releaseTask.value

        XCTAssertNil(weakSubject)
    }
}

@MainActor
private final class ShortcutMonitorHarness {
    enum Action: Equatable {
        case start
        case stop
        case cancel
    }

    let scheduler = ManualHoldScheduler()
    let eventMonitors = LocalEventMonitorHarness()
    var now: TimeInterval = 0
    var configuredKeyIsDown = false
    var isEligible: Bool
    private(set) var actions: [Action] = []
    private let shortcut: VoiceInputConfig.Shortcut

    lazy var subject = WritingDictationShortcutMonitor(
        scheduleHold: { [scheduler] delay, action in
            scheduler.schedule(after: delay, action: action)
        },
        currentTime: { [weak self] in self?.now ?? 0 },
        configuredKeyState: { [weak self] _ in self?.configuredKeyIsDown == true },
        addLocalMonitor: { [eventMonitors] mask, handler in
            eventMonitors.add(mask: mask, handler: handler)
        },
        removeLocalMonitor: { [eventMonitors] monitor in
            eventMonitors.remove(monitor)
        }
    )

    init(
        shortcut: VoiceInputConfig.Shortcut = .rightOption,
        isEligible: Bool = true
    ) {
        self.shortcut = shortcut
        self.isEligible = isEligible
        subject.configure(
            shortcut: shortcut,
            isEligible: { [weak self] in self?.isEligible == true },
            onStart: { [weak self] in self?.actions.append(.start) },
            onStop: { [weak self] in self?.actions.append(.stop) },
            onCancel: { [weak self] in self?.actions.append(.cancel) }
        )
    }

    func activateEditorContext() {
        subject.activateEditorContext()
    }

    @discardableResult
    func sendModifier(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        configuredKeyIsDown: Bool? = nil
    ) -> (sent: NSEvent, returned: NSEvent) {
        if keyCode == shortcut.keyCode {
            self.configuredKeyIsDown = configuredKeyIsDown
                ?? flags.contains(shortcut.modifierFlag)
        }
        return send(type: .flagsChanged, keyCode: keyCode, flags: flags)
    }

    @discardableResult
    func sendKeyDown(keyCode: UInt16) -> (sent: NSEvent, returned: NSEvent) {
        send(type: .keyDown, keyCode: keyCode, flags: [])
    }

    private func send(
        type: NSEvent.EventType,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> (sent: NSEvent, returned: NSEvent) {
        let event = makeKeyEvent(type: type, keyCode: keyCode, flags: flags)
        return (event, subject.handle(event))
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

@MainActor
private final class ManualHoldScheduler {
    private(set) var delays: [TimeInterval] = []
    private var holds: [ManualCancellableHold] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any CancellableHold {
        delays.append(delay)
        let hold = ManualCancellableHold(action: action)
        holds.append(hold)
        return hold
    }

    func fireNext() {
        guard !holds.isEmpty else { return }
        holds.removeFirst().fire()
    }
}

@MainActor
private final class ManualCancellableHold: CancellableHold {
    private var action: (@MainActor () -> Void)?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func cancel() {
        action = nil
    }

    func fire() {
        let action = action
        self.action = nil
        action?()
    }
}

@MainActor
private final class LocalEventMonitorHarness {
    private(set) var addCount = 0
    private(set) var removeCount = 0
    private(set) var masks: [NSEvent.EventTypeMask] = []
    private(set) var handler: ((NSEvent) -> NSEvent?)?
    private let token = NSObject()

    func add(
        mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        addCount += 1
        masks.append(mask)
        self.handler = handler
        return token
    }

    func remove(_ monitor: Any) {
        XCTAssertTrue((monitor as AnyObject) === token)
        removeCount += 1
        handler = nil
    }
}

private func makeKeyEvent(
    type: NSEvent.EventType,
    keyCode: UInt16,
    flags: NSEvent.ModifierFlags
) -> NSEvent {
    NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: flags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    )!
}
