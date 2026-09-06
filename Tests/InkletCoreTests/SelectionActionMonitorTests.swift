import AppKit
import XCTest

@testable import Inklet

final class SelectionActionMonitorTests: XCTestCase {
    @MainActor
    func testEveryRequiredMonitorRegistrationFailureRollsBackAndCanRetry() {
        for failureIndex in 0..<5 {
            let tracker = SelectionInteractionTracker()
            _ = tracker.begin(.mouse)
            let installation = ControlledSelectionMonitorInstallation(failureIndex: failureIndex)
            let copyTap = ControlledSelectionCopyTapLifecycle(startResults: [true, true])
            let scheduler = ControlledSelectionMonitorHandoffScheduler()
            let monitor = makeMonitor(
                tracker: tracker,
                installation: installation,
                copyTap: copyTap,
                scheduler: scheduler
            )

            XCTAssertFalse(monitor.start(), "registration index \(failureIndex)")
            XCTAssertEqual(installation.registrationCount, failureIndex + 1)
            XCTAssertEqual(installation.activeTokenCount, 0)
            XCTAssertEqual(installation.removalCount, failureIndex)
            XCTAssertEqual(copyTap.stopCount, 1)
            XCTAssertFalse(tracker.isActive)
            XCTAssertFalse(monitor.isInteractionActive)

            installation.failureIndex = nil
            XCTAssertTrue(monitor.start(), "retry after registration index \(failureIndex)")
            XCTAssertEqual(installation.activeTokenCount, 5)
            monitor.stop()
        }
    }

    @MainActor
    func testCopyTapInstallationFailureDoesNotInstallMonitorsAndCanRetry() {
        let tracker = SelectionInteractionTracker()
        _ = tracker.begin(.copy)
        let installation = ControlledSelectionMonitorInstallation()
        let copyTap = ControlledSelectionCopyTapLifecycle(startResults: [false, true])
        let scheduler = ControlledSelectionMonitorHandoffScheduler()
        let monitor = makeMonitor(
            tracker: tracker,
            installation: installation,
            copyTap: copyTap,
            scheduler: scheduler
        )

        XCTAssertFalse(monitor.start())
        XCTAssertEqual(installation.registrationCount, 0)
        XCTAssertEqual(installation.activeTokenCount, 0)
        XCTAssertEqual(copyTap.stopCount, 1)
        XCTAssertFalse(tracker.isActive)
        XCTAssertFalse(monitor.isInteractionActive)

        XCTAssertTrue(monitor.start())
        XCTAssertEqual(installation.activeTokenCount, 5)
        monitor.stop()
    }

    @MainActor
    func testQueuedEventFromStoppedSessionCannotAffectQuickRestart() throws {
        let tracker = SelectionInteractionTracker()
        let installation = ControlledSelectionMonitorInstallation()
        let copyTap = ControlledSelectionCopyTapLifecycle(startResults: [true, true])
        let scheduler = ControlledSelectionMonitorHandoffScheduler()
        let monitor = makeMonitor(
            tracker: tracker,
            installation: installation,
            copyTap: copyTap,
            scheduler: scheduler
        )
        var candidateCount = 0
        var interactionStates: [Bool] = []
        monitor.onCandidateSelection = { _ in candidateCount += 1 }
        monitor.onInteractionStateChange = { interactionStates.append($0) }

        XCTAssertTrue(monitor.start())
        let oldKeyUp = try XCTUnwrap(installation.latestHandler(matching: [.keyUp]))
        oldKeyUp(try makeShiftKeyUpEvent(timestamp: 1))
        XCTAssertTrue(tracker.isActive)

        monitor.stop()
        XCTAssertTrue(monitor.start())
        interactionStates.removeAll()
        let newKeyUp = try XCTUnwrap(installation.latestHandler(matching: [.keyUp]))
        newKeyUp(try makeShiftKeyUpEvent(timestamp: 2))
        XCTAssertTrue(tracker.isActive)

        scheduler.runAction(at: 0)
        XCTAssertEqual(candidateCount, 0)
        XCTAssertTrue(tracker.isActive)
        XCTAssertTrue(monitor.isInteractionActive)
        XCTAssertTrue(interactionStates.isEmpty)

        scheduler.runAction(at: 1)
        XCTAssertEqual(candidateCount, 1)
        XCTAssertFalse(tracker.isActive)
        XCTAssertFalse(monitor.isInteractionActive)
        XCTAssertEqual(interactionStates, [true, false])
        monitor.stop()
    }

    @MainActor
    func testRawMouseHandlersKeepInteractionActiveThroughMouseUpHandoff() throws {
        let tracker = SelectionInteractionTracker()
        let installation = ControlledSelectionMonitorInstallation()
        let copyTap = ControlledSelectionCopyTapLifecycle(startResults: [true])
        let scheduler = ControlledSelectionMonitorHandoffScheduler()
        let monitor = makeMonitor(
            tracker: tracker,
            installation: installation,
            copyTap: copyTap,
            scheduler: scheduler
        )

        XCTAssertTrue(monitor.start())
        let pointerHandler = try XCTUnwrap(installation.latestHandler(
            matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]
        ))
        let mouseUpHandler = try XCTUnwrap(installation.latestHandler(matching: [.leftMouseUp]))

        pointerHandler(try makeMouseEvent(type: .leftMouseDown, timestamp: 1))
        XCTAssertTrue(tracker.isActive)
        mouseUpHandler(try makeMouseEvent(type: .leftMouseUp, timestamp: 2))
        XCTAssertTrue(tracker.isActive)

        scheduler.runAction(at: 1)
        XCTAssertFalse(tracker.isActive)
        XCTAssertFalse(monitor.isInteractionActive)
        monitor.stop()
    }

    @MainActor
    func testRawShiftHandlersKeepInteractionActiveThroughKeyUpHandoff() throws {
        let tracker = SelectionInteractionTracker()
        let installation = ControlledSelectionMonitorInstallation()
        let copyTap = ControlledSelectionCopyTapLifecycle(startResults: [true])
        let scheduler = ControlledSelectionMonitorHandoffScheduler()
        let monitor = makeMonitor(
            tracker: tracker,
            installation: installation,
            copyTap: copyTap,
            scheduler: scheduler
        )
        var candidateCount = 0
        monitor.onCandidateSelection = { _ in candidateCount += 1 }

        XCTAssertTrue(monitor.start())
        let flagsHandler = try XCTUnwrap(installation.latestHandler(matching: [.flagsChanged]))
        let keyUpHandler = try XCTUnwrap(installation.latestHandler(matching: [.keyUp]))

        flagsHandler(try makeKeyEvent(type: .flagsChanged, modifiers: [.shift], timestamp: 1))
        XCTAssertTrue(tracker.isActive)
        keyUpHandler(try makeShiftKeyUpEvent(timestamp: 2))
        flagsHandler(try makeKeyEvent(type: .flagsChanged, modifiers: [], timestamp: 3))
        XCTAssertTrue(tracker.isActive)

        scheduler.runAction(at: 1)
        XCTAssertEqual(candidateCount, 1)
        XCTAssertFalse(tracker.isActive)
        XCTAssertFalse(monitor.isInteractionActive)
        monitor.stop()
    }

    @MainActor
    private func makeMonitor(
        tracker: SelectionInteractionTracker,
        installation: ControlledSelectionMonitorInstallation,
        copyTap: ControlledSelectionCopyTapLifecycle,
        scheduler: ControlledSelectionMonitorHandoffScheduler
    ) -> SelectionActionMonitor {
        SelectionActionMonitor(
            interactionTracker: tracker,
            physicalInteractionStateProvider: {
                SelectionPhysicalInteractionState(
                    isLeftMouseButtonPressed: false,
                    isShiftPressed: false
                )
            },
            monitorRegistrar: installation.register,
            monitorRemover: installation.remove,
            handoffScheduler: scheduler.enqueue,
            copyEventTapStarter: copyTap.start,
            copyEventTapStopper: copyTap.stop
        )
    }

    private func makeShiftKeyUpEvent(timestamp: TimeInterval) throws -> NSEvent {
        try makeKeyEvent(type: .keyUp, modifiers: [.shift], timestamp: timestamp)
    }

    private func makeKeyEvent(
        type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags,
        timestamp: TimeInterval
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 56
        ))
    }

    private func makeMouseEvent(type: NSEvent.EventType, timestamp: TimeInterval) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
    }
}

@MainActor
private final class ControlledSelectionMonitorInstallation {
    struct Registration {
        let mask: NSEvent.EventTypeMask
        let handler: SelectionActionMonitor.EventHandler
        let token: Token
    }

    final class Token {}

    var failureIndex: Int?
    private(set) var registrationCount = 0
    private(set) var removalCount = 0
    private(set) var registrations: [Registration] = []
    private var activeTokens: Set<ObjectIdentifier> = []

    var activeTokenCount: Int {
        activeTokens.count
    }

    init(failureIndex: Int? = nil) {
        self.failureIndex = failureIndex
    }

    func register(
        _ mask: NSEvent.EventTypeMask,
        _ handler: @escaping SelectionActionMonitor.EventHandler
    ) -> Any? {
        let index = registrationCount
        registrationCount += 1
        guard failureIndex != index else { return nil }
        let token = Token()
        registrations.append(Registration(mask: mask, handler: handler, token: token))
        activeTokens.insert(ObjectIdentifier(token))
        return token
    }

    func remove(_ token: Any) {
        guard let token = token as? Token else { return }
        removalCount += 1
        activeTokens.remove(ObjectIdentifier(token))
    }

    func latestHandler(matching mask: NSEvent.EventTypeMask) -> SelectionActionMonitor.EventHandler? {
        registrations.last(where: { $0.mask == mask })?.handler
    }
}

@MainActor
private final class ControlledSelectionCopyTapLifecycle {
    private var startResults: [Bool]
    private(set) var stopCount = 0

    init(startResults: [Bool]) {
        self.startResults = startResults
    }

    func start(
        _ onInteractionBegin: @escaping SelectionCopyEventTap.InteractionHandler,
        _ onInteractionEnd: @escaping SelectionCopyEventTap.InteractionHandler,
        _ onCopyTrigger: @escaping SelectionCopyEventTap.CopyTriggerHandler
    ) -> Bool {
        _ = onInteractionBegin
        _ = onInteractionEnd
        _ = onCopyTrigger
        return startResults.removeFirst()
    }

    func stop() {
        stopCount += 1
    }
}

private final class ControlledSelectionMonitorHandoffScheduler: @unchecked Sendable {
    typealias Action = @MainActor @Sendable () -> Void

    private let lock = NSLock()
    private var actions: [Action] = []

    func enqueue(_ action: @escaping Action) {
        lock.lock()
        actions.append(action)
        lock.unlock()
    }

    @MainActor
    func runAction(at index: Int) {
        lock.lock()
        let action = actions[index]
        lock.unlock()
        action()
    }
}
