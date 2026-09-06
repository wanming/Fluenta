import AppKit
import XCTest

@testable import Inklet

final class SelectionActionMonitorTests: XCTestCase {
    @MainActor
    func testEveryRequiredMonitorRegistrationFailureRollsBackAndCanRetry() {
        for failureIndex in 0..<6 {
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
            XCTAssertEqual(installation.activeTokenCount, 6)
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
        XCTAssertEqual(installation.activeTokenCount, 6)
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
    func testLocalShiftReleaseEndsInteractionStartedOutsideInklet() throws {
        let tracker = SelectionInteractionTracker()
        let installation = ControlledSelectionMonitorInstallation()
        let scheduler = ControlledSelectionMonitorHandoffScheduler()
        let monitor = makeMonitor(
            tracker: tracker,
            installation: installation,
            copyTap: ControlledSelectionCopyTapLifecycle(startResults: [true]),
            scheduler: scheduler
        )
        var interactionStates: [Bool] = []
        monitor.onInteractionStateChange = { interactionStates.append($0) }
        monitor.onCandidateSelection = { _ in XCTFail("Local events must not select text") }
        monitor.onDismiss = { _ in XCTFail("Local events must not dismiss selection UI") }

        XCTAssertTrue(monitor.start())
        let globalFlags = try XCTUnwrap(installation.latestHandler(matching: [.flagsChanged]))
        let local = try XCTUnwrap(installation.latestLocalHandler())
        globalFlags(try makeKeyEvent(type: .flagsChanged, modifiers: [.shift], timestamp: 1))
        scheduler.runAction(at: 0)
        XCTAssertTrue(monitor.isInteractionActive)

        let release = try makeKeyEvent(type: .flagsChanged, modifiers: [], timestamp: 2)
        XCTAssertTrue(local(release) === release)
        XCTAssertFalse(tracker.isActive)
        scheduler.runAction(at: 1)
        XCTAssertFalse(monitor.isInteractionActive)
        XCTAssertEqual(interactionStates, [true, false])
        monitor.stop()
    }

    @MainActor
    func testLocalMouseReleaseEndsInteractionStartedOutsideInklet() throws {
        let tracker = SelectionInteractionTracker()
        let installation = ControlledSelectionMonitorInstallation()
        let scheduler = ControlledSelectionMonitorHandoffScheduler()
        let monitor = makeMonitor(
            tracker: tracker,
            installation: installation,
            copyTap: ControlledSelectionCopyTapLifecycle(startResults: [true]),
            scheduler: scheduler
        )
        var interactionStates: [Bool] = []
        monitor.onInteractionStateChange = { interactionStates.append($0) }
        monitor.onCandidateSelection = { _ in XCTFail("Local events must not select text") }
        monitor.onDismiss = { _ in XCTFail("Local events must not dismiss selection UI") }

        XCTAssertTrue(monitor.start())
        let pointer = try XCTUnwrap(installation.latestHandler(
            matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]
        ))
        let local = try XCTUnwrap(installation.latestLocalHandler())
        pointer(try makeMouseEvent(type: .leftMouseDown, timestamp: 1))
        scheduler.runAction(at: 0)
        XCTAssertTrue(monitor.isInteractionActive)

        let release = try makeMouseEvent(type: .leftMouseUp, timestamp: 2)
        XCTAssertTrue(local(release) === release)
        XCTAssertFalse(tracker.isActive)
        scheduler.runAction(at: 1)
        XCTAssertFalse(monitor.isInteractionActive)
        XCTAssertEqual(interactionStates, [true, false])
        monitor.stop()
    }

    @MainActor
    func testLocalReleasePreservesPendingGlobalSelectionHandoff() throws {
        let tracker = SelectionInteractionTracker()
        let installation = ControlledSelectionMonitorInstallation()
        let scheduler = ControlledSelectionMonitorHandoffScheduler()
        let monitor = makeMonitor(
            tracker: tracker,
            installation: installation,
            copyTap: ControlledSelectionCopyTapLifecycle(startResults: [true]),
            scheduler: scheduler
        )
        var candidateCount = 0
        var interactionStates: [Bool] = []
        monitor.onCandidateSelection = { _ in
            XCTAssertTrue(tracker.isActive)
            candidateCount += 1
        }
        monitor.onInteractionStateChange = { interactionStates.append($0) }

        XCTAssertTrue(monitor.start())
        let flags = try XCTUnwrap(installation.latestHandler(matching: [.flagsChanged]))
        let keyUp = try XCTUnwrap(installation.latestHandler(matching: [.keyUp]))
        let local = try XCTUnwrap(installation.latestLocalHandler())
        flags(try makeKeyEvent(type: .flagsChanged, modifiers: [.shift], timestamp: 1))
        scheduler.runAction(at: 0)
        keyUp(try makeShiftKeyUpEvent(timestamp: 2))
        let release = try makeKeyEvent(type: .flagsChanged, modifiers: [], timestamp: 3)
        XCTAssertTrue(local(release) === release)
        scheduler.runAction(at: 2)
        XCTAssertTrue(monitor.isInteractionActive)
        XCTAssertEqual(interactionStates, [true])

        scheduler.runAction(at: 1)
        XCTAssertEqual(candidateCount, 1)
        XCTAssertFalse(monitor.isInteractionActive)
        XCTAssertEqual(interactionStates, [true, false])
        monitor.stop()
    }

    @MainActor
    func testEntirelyLocalInteractionsRetryBlockedAutomaticUpdate() throws {
        for kind in [SelectionInteractionTracker.Kind.keyboard, .mouse] {
            let tracker = SelectionInteractionTracker()
            let installation = ControlledSelectionMonitorInstallation()
            let scheduler = ControlledSelectionMonitorHandoffScheduler()
            let monitor = makeMonitor(
                tracker: tracker,
                installation: installation,
                copyTap: ControlledSelectionCopyTapLifecycle(startResults: [true]),
                scheduler: scheduler
            )
            let deferrer = ControlledSelectionMonitorUpdateDeferrer()
            var presentationCount = 0
            let gate = AutomaticUpdatePresentationGate(
                canPresent: { !monitor.isInteractionActive },
                present: { presentationCount += 1 },
                deferAction: deferrer.enqueue
            )
            monitor.onInteractionStateChange = { active in
                if !active { gate.schedule() }
            }
            monitor.onCandidateSelection = { _ in XCTFail("Local events must not select text") }
            monitor.onDismiss = { _ in XCTFail("Local events must not dismiss selection UI") }

            XCTAssertTrue(monitor.start())
            let local = try XCTUnwrap(installation.latestLocalHandler())
            let press = try kind == .keyboard
                ? makeKeyEvent(type: .flagsChanged, modifiers: [.shift], timestamp: 1)
                : makeMouseEvent(type: .leftMouseDown, timestamp: 1)
            XCTAssertTrue(local(press) === press)
            XCTAssertTrue(monitor.isInteractionActive)
            scheduler.runAction(at: 0)

            gate.schedule()
            deferrer.runAction(at: 0)
            XCTAssertEqual(presentationCount, 0)

            let release = try kind == .keyboard
                ? makeKeyEvent(type: .flagsChanged, modifiers: [], timestamp: 2)
                : makeMouseEvent(type: .leftMouseUp, timestamp: 2)
            XCTAssertTrue(local(release) === release)
            XCTAssertFalse(monitor.isInteractionActive)
            scheduler.runAction(at: 1)
            XCTAssertEqual(deferrer.actions.count, 2)
            deferrer.runAction(at: 1)
            XCTAssertEqual(presentationCount, 1)
            monitor.stop()
        }
    }

    @MainActor
    func testLocalCallbacksFromStoppedSessionCannotAffectQuickRestart() throws {
        let tracker = SelectionInteractionTracker()
        let installation = ControlledSelectionMonitorInstallation()
        let scheduler = ControlledSelectionMonitorHandoffScheduler()
        let monitor = makeMonitor(
            tracker: tracker,
            installation: installation,
            copyTap: ControlledSelectionCopyTapLifecycle(startResults: [true, true]),
            scheduler: scheduler
        )
        var interactionStates: [Bool] = []
        monitor.onInteractionStateChange = { interactionStates.append($0) }

        XCTAssertTrue(monitor.start())
        let oldLocal = try XCTUnwrap(installation.latestLocalHandler())
        let press = try makeKeyEvent(type: .flagsChanged, modifiers: [.shift], timestamp: 1)
        XCTAssertTrue(oldLocal(press) === press)
        XCTAssertTrue(tracker.isActive)
        monitor.stop()
        XCTAssertEqual(installation.activeTokenCount, 0)
        XCTAssertTrue(monitor.start())
        interactionStates.removeAll()

        let local = try XCTUnwrap(installation.latestLocalHandler())
        XCTAssertTrue(local(press) === press)
        let release = try makeKeyEvent(type: .flagsChanged, modifiers: [], timestamp: 2)
        XCTAssertTrue(oldLocal(release) === release)
        scheduler.runAction(at: 0)
        XCTAssertTrue(tracker.isActive)
        XCTAssertTrue(interactionStates.isEmpty)

        scheduler.runAction(at: 1)
        XCTAssertEqual(interactionStates, [true])
        XCTAssertTrue(local(release) === release)
        scheduler.runAction(at: 2)
        XCTAssertFalse(monitor.isInteractionActive)
        XCTAssertEqual(interactionStates, [true, false])
        monitor.stop()
        XCTAssertEqual(installation.activeTokenCount, 0)
        XCTAssertTrue(local(press) === press)
        XCTAssertFalse(tracker.isActive)
    }

    @MainActor
    func testLocalReleaseClearsPhysicalStateSeededAtStartup() throws {
        for kind in [SelectionInteractionTracker.Kind.keyboard, .mouse] {
            let tracker = SelectionInteractionTracker()
            let installation = ControlledSelectionMonitorInstallation()
            let scheduler = ControlledSelectionMonitorHandoffScheduler()
            let physicalState = ControlledSelectionMonitorPhysicalState(
                SelectionPhysicalInteractionState(
                    isLeftMouseButtonPressed: kind == .mouse,
                    isShiftPressed: kind == .keyboard
                )
            )
            let monitor = makeMonitor(
                tracker: tracker,
                installation: installation,
                copyTap: ControlledSelectionCopyTapLifecycle(startResults: [true]),
                scheduler: scheduler,
                physicalInteractionStateProvider: { physicalState.value }
            )
            var interactionStates: [Bool] = []
            monitor.onInteractionStateChange = { interactionStates.append($0) }

            XCTAssertTrue(monitor.start())
            XCTAssertTrue(tracker.isActive)
            XCTAssertTrue(monitor.isInteractionActive)
            let local = try XCTUnwrap(installation.latestLocalHandler())
            physicalState.value = SelectionPhysicalInteractionState(
                isLeftMouseButtonPressed: false,
                isShiftPressed: false
            )
            let release = try kind == .keyboard
                ? makeKeyEvent(type: .flagsChanged, modifiers: [], timestamp: 1)
                : makeMouseEvent(type: .leftMouseUp, timestamp: 1)
            XCTAssertTrue(local(release) === release)
            XCTAssertFalse(tracker.isActive)
            scheduler.runAction(at: 0)
            XCTAssertFalse(monitor.isInteractionActive)
            XCTAssertEqual(interactionStates, [true, false])
            monitor.stop()
        }
    }

    @MainActor
    private func makeMonitor(
        tracker: SelectionInteractionTracker,
        installation: ControlledSelectionMonitorInstallation,
        copyTap: ControlledSelectionCopyTapLifecycle,
        scheduler: ControlledSelectionMonitorHandoffScheduler,
        physicalInteractionStateProvider: @escaping SelectionActionMonitor.PhysicalInteractionStateProvider = {
            SelectionPhysicalInteractionState(
                isLeftMouseButtonPressed: false,
                isShiftPressed: false
            )
        }
    ) -> SelectionActionMonitor {
        SelectionActionMonitor(
            interactionTracker: tracker,
            physicalInteractionStateProvider: physicalInteractionStateProvider,
            monitorRegistrar: installation.register,
            localMonitorRegistrar: installation.registerLocal,
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

    struct LocalRegistration {
        let mask: NSEvent.EventTypeMask
        let handler: SelectionActionMonitor.LocalEventHandler
        let token: Token
    }

    final class Token {}

    var failureIndex: Int?
    private(set) var registrationCount = 0
    private(set) var removalCount = 0
    private(set) var registrations: [Registration] = []
    private(set) var localRegistrations: [LocalRegistration] = []
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

    func registerLocal(
        _ mask: NSEvent.EventTypeMask,
        _ handler: @escaping SelectionActionMonitor.LocalEventHandler
    ) -> Any? {
        let index = registrationCount
        registrationCount += 1
        guard failureIndex != index else { return nil }
        let token = Token()
        localRegistrations.append(LocalRegistration(mask: mask, handler: handler, token: token))
        activeTokens.insert(ObjectIdentifier(token))
        return token
    }

    func latestHandler(matching mask: NSEvent.EventTypeMask) -> SelectionActionMonitor.EventHandler? {
        registrations.last(where: { $0.mask == mask })?.handler
    }

    func latestLocalHandler() -> SelectionActionMonitor.LocalEventHandler? {
        localRegistrations.last(where: {
            $0.mask == [.flagsChanged, .leftMouseDown, .leftMouseUp]
        })?.handler
    }
}

@MainActor
private final class ControlledSelectionMonitorPhysicalState {
    var value: SelectionPhysicalInteractionState

    init(_ value: SelectionPhysicalInteractionState) {
        self.value = value
    }
}

@MainActor
private final class ControlledSelectionMonitorUpdateDeferrer {
    private(set) var actions: [AutomaticUpdatePresentationGate.DeferredAction] = []

    func enqueue(
        _ action: @escaping AutomaticUpdatePresentationGate.DeferredAction
    ) -> @MainActor () -> Void {
        actions.append(action)
        return {}
    }

    func runAction(at index: Int) {
        actions[index]()
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
