import CoreGraphics
import XCTest
@testable import Inklet
@testable import InkletCore

final class SelectionCopyEventTapTests: XCTestCase {
    @MainActor
    func testConfigurationUsesAnnotatedHeadDefaultKeyDownTap() {
        XCTAssertEqual(SelectionCopyEventTap.tapLocation, .cgAnnotatedSessionEventTap)
        XCTAssertEqual(SelectionCopyEventTap.tapPlacement, .headInsertEventTap)
        XCTAssertEqual(SelectionCopyEventTap.tapOptions, .defaultTap)
        XCTAssertEqual(
            SelectionCopyEventTap.eventMask,
            CGEventMask(1 << CGEventType.keyDown.rawValue)
        )
    }

    @MainActor
    func testHandlerAlwaysReturnsExactOriginalEvent() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: true
        ))
        let tap = SelectionCopyEventTap()

        let returned = tap.handleEvent(type: .keyDown, event: event).takeUnretainedValue()

        XCTAssertTrue(returned === event)
    }

    @MainActor
    func testFirstPhysicalCopyRecordsAndSecondTriggersWithFrozenFields() {
        let state = SelectionCopyEventTapTestState()
        let tap = SelectionCopyEventTap(
            mouseLocationProvider: { state.point },
            onCopyTrigger: { state.triggers.append($0) }
        )

        tap.handleEventFields(copyFields(pid: 42, timestamp: 10))
        state.point = SelectionPoint(x: 33, y: 44)
        tap.handleEventFields(copyFields(pid: 84, timestamp: 10.5))

        XCTAssertEqual(state.triggers, [
            SelectionCopyEventTap.Trigger(
                sourceProcessIdentifier: 84,
                point: SelectionPoint(x: 33, y: 44),
                timestamp: 10.5
            )
        ])
    }

    @MainActor
    func testOrdinaryAndModifiedKeysDoNotRecordOrTriggerCopyPolicy() {
        var triggers: [SelectionCopyEventTap.Trigger] = []
        let tap = SelectionCopyEventTap(onCopyTrigger: { triggers.append($0) })

        tap.handleEventFields(SelectionCopyEventTap.EventFields(
            type: .keyDown,
            keyCode: 0,
            flags: .maskCommand,
            userData: 0,
            targetProcessIdentifier: 42,
            timestamp: 10
        ))
        tap.handleEventFields(copyFields(pid: 42, timestamp: 10.1, flags: [.maskCommand, .maskShift]))
        tap.handleEventFields(copyFields(pid: 42, timestamp: 10.2))

        XCTAssertTrue(triggers.isEmpty)
    }

    @MainActor
    func testEveryExtraDeviceIndependentModifierRejectsWithoutRecordingCopyPolicy() {
        let extraModifierCases: [(String, CGEventFlags)] = [
            ("shift", .maskShift),
            ("control", .maskControl),
            ("option", .maskAlternate),
            ("function", .maskSecondaryFn),
            ("numeric pad", .maskNumericPad),
            ("help", .maskHelp),
            ("function and numeric pad", [.maskSecondaryFn, .maskNumericPad]),
            ("help and shift", [.maskHelp, .maskShift]),
            ("option, control, and function", [.maskAlternate, .maskControl, .maskSecondaryFn])
        ]

        for (name, extraModifiers) in extraModifierCases {
            var triggers: [SelectionCopyEventTap.Trigger] = []
            let tap = SelectionCopyEventTap(onCopyTrigger: { triggers.append($0) })

            tap.handleEventFields(copyFields(
                pid: 42,
                timestamp: 10,
                flags: [.maskCommand, extraModifiers]
            ))
            tap.handleEventFields(copyFields(pid: 42, timestamp: 10.1))

            XCTAssertTrue(triggers.isEmpty, "Command+C with \(name) must not record policy")

            tap.handleEventFields(copyFields(pid: 42, timestamp: 10.2))

            XCTAssertEqual(triggers.count, 1, "Plain Command+C must still trigger after \(name)")
        }
    }

    @MainActor
    func testSyntheticMarkedCopyIsIgnoredWithoutRecordingPolicy() {
        var triggers: [SelectionCopyEventTap.Trigger] = []
        let tap = SelectionCopyEventTap(onCopyTrigger: { triggers.append($0) })

        tap.handleEventFields(copyFields(
            pid: 42,
            timestamp: 10,
            userData: SelectionClipboardReader.syntheticCopyEventUserData
        ))
        tap.handleEventFields(copyFields(pid: 42, timestamp: 10.1))

        XCTAssertTrue(triggers.isEmpty)
    }

    @MainActor
    func testCapsLockDoesNotPreventExactCommandCopyRecognition() {
        var triggers: [SelectionCopyEventTap.Trigger] = []
        let tap = SelectionCopyEventTap(onCopyTrigger: { triggers.append($0) })

        tap.handleEventFields(copyFields(
            pid: 42,
            timestamp: 10,
            flags: [.maskCommand, .maskAlphaShift]
        ))
        tap.handleEventFields(copyFields(
            pid: 42,
            timestamp: 10.5,
            flags: [.maskCommand, .maskAlphaShift]
        ))

        XCTAssertEqual(triggers.count, 1)
    }

    @MainActor
    func testDisabledEventsUseReenableSeamAndReturnOriginalEvents() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: true
        ))
        var enableCalls: [Bool] = []
        let tap = SelectionCopyEventTap(
            tapEnableHandler: { _, enabled in enableCalls.append(enabled) }
        )

        let timeoutResult = tap.handleEvent(
            type: .tapDisabledByTimeout,
            event: event
        ).takeUnretainedValue()
        let inputResult = tap.handleEvent(
            type: .tapDisabledByUserInput,
            event: event
        ).takeUnretainedValue()

        XCTAssertTrue(timeoutResult === event)
        XCTAssertTrue(inputResult === event)
        XCTAssertEqual(enableCalls, [true, true])
    }

    func testLifecycleSourceUsesMainCommonRunLoopAndNeverRequestsListenAccess() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent(
            "Sources/InkletApp/SelectionCopyEventTap.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("tap: Self.tapLocation"))
        XCTAssertTrue(source.contains("place: Self.tapPlacement"))
        XCTAssertTrue(source.contains("options: Self.tapOptions"))
        XCTAssertTrue(source.contains("eventsOfInterest: Self.eventMask"))
        XCTAssertTrue(source.contains("CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)"))
        XCTAssertTrue(source.contains("CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)"))
        XCTAssertTrue(source.contains("tapEnableHandler(eventTap, false)"))
        XCTAssertTrue(source.contains("CFMachPortInvalidate(eventTap)"))
        XCTAssertTrue(source.contains("MainActor.assumeIsolated"))
        XCTAssertFalse(source.contains("CGRequestListenEventAccess"))
        XCTAssertFalse(source.contains("CGPreflightListenEventAccess"))
        XCTAssertFalse(source.contains(".listenOnly"))
    }

    private func copyFields(
        pid: pid_t,
        timestamp: TimeInterval,
        flags: CGEventFlags = .maskCommand,
        userData: Int64 = 0
    ) -> SelectionCopyEventTap.EventFields {
        SelectionCopyEventTap.EventFields(
            type: .keyDown,
            keyCode: 8,
            flags: flags,
            userData: userData,
            targetProcessIdentifier: pid,
            timestamp: timestamp
        )
    }
}

@MainActor
private final class SelectionCopyEventTapTestState {
    var point = SelectionPoint(x: 11, y: 22)
    var triggers: [SelectionCopyEventTap.Trigger] = []
}
