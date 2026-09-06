import XCTest

final class SelectionActionMonitorSourceTests: XCTestCase {
    func testLocalInteractionMonitorUsesAppKitPassthroughObservation() throws {
        let source = try monitorSource()

        XCTAssertTrue(source.contains("NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)"))
        XCTAssertTrue(source.contains("localMonitorRegistrar("))
    }

    func testCopyTapCallbackIsForwardedSynchronouslyWithoutTaskHop() throws {
        let source = try monitorSource()
        let startRange = try XCTUnwrap(source.range(of: "func start()"))
        let firstMonitorRange = try XCTUnwrap(source.range(
            of: "guard registerMonitor(matching:",
            range: startRange.upperBound..<source.endIndex
        ))
        let startBlock = source[startRange.lowerBound..<firstMonitorRange.lowerBound]

        XCTAssertTrue(source.contains("var onCopyTrigger: ((SelectionCopyEventTap.Trigger) -> Void)?"))
        XCTAssertTrue(source.contains("private let copyEventTap: SelectionCopyEventTap"))
        XCTAssertTrue(startBlock.contains("copyEventTapStarter("))
        XCTAssertTrue(startBlock.contains("self?.onCopyTrigger?(trigger)"))
        XCTAssertFalse(startBlock.contains("handoffScheduler {"))
        XCTAssertFalse(source.contains("SelectionCopyTriggerPolicy"))
        XCTAssertFalse(source.contains("NSPasteboard.general.changeCount"))
    }

    func testGlobalKeyDownCopyOnlyBypassesDismissal() throws {
        let source = try monitorSource()
        let keyDownMonitorStart = try XCTUnwrap(source.range(
            of: "registerMonitor(matching: [.keyDown]"
        ))
        let dismissalMonitorStart = try XCTUnwrap(source.range(
            of: "registerMonitor(\n            matching: [.scrollWheel",
            range: keyDownMonitorStart.upperBound..<source.endIndex
        ))
        let keyDownMonitorBlock = source[keyDownMonitorStart.lowerBound..<dismissalMonitorStart.lowerBound]

        XCTAssertTrue(keyDownMonitorBlock.contains("guard !Self.isCopyShortcut(event) else"))
        XCTAssertTrue(keyDownMonitorBlock.contains("return"))
        XCTAssertFalse(keyDownMonitorBlock.contains("recordCopy"))
        XCTAssertFalse(keyDownMonitorBlock.contains("onCopyTrigger"))
        XCTAssertTrue(source.contains(".subtracting(.capsLock)"))
    }

    func testCandidateMouseUpMonitorDoesNotObserveRightMouseUp() throws {
        let source = try monitorSource()
        let mouseUpMonitorStart = try XCTUnwrap(source.range(
            of: "registerMonitor(matching: [.leftMouseUp]"
        ))
        let keyUpMonitorStart = try XCTUnwrap(source.range(
            of: "registerMonitor(matching: [.keyUp]",
            range: mouseUpMonitorStart.upperBound..<source.endIndex
        ))
        let mouseUpMonitorBlock = source[mouseUpMonitorStart.lowerBound..<keyUpMonitorStart.lowerBound]

        XCTAssertTrue(mouseUpMonitorBlock.contains("matching: [.leftMouseUp]"))
        XCTAssertFalse(mouseUpMonitorBlock.contains(".rightMouseDown"))
        XCTAssertFalse(mouseUpMonitorBlock.contains(".rightMouseUp"))
    }

    func testShiftKeyUpCandidateMonitorRemainsInstalled() throws {
        let source = try monitorSource()
        let keyUpMonitorStart = try XCTUnwrap(source.range(
            of: "registerMonitor(matching: [.keyUp]"
        ))
        let keyDownMonitorStart = try XCTUnwrap(source.range(
            of: "registerMonitor(matching: [.keyDown]",
            range: keyUpMonitorStart.upperBound..<source.endIndex
        ))
        let keyUpMonitorBlock = source[keyUpMonitorStart.lowerBound..<keyDownMonitorStart.lowerBound]

        XCTAssertTrue(keyUpMonitorBlock.contains("modifiers.contains(.shift)"))
        XCTAssertTrue(keyUpMonitorBlock.contains("onCandidateSelection?"))
    }

    func testRawSelectionBoundariesTrackActivityBeforeTaskHandoffs() throws {
        let source = try monitorSource()
        let mouseUpStart = try XCTUnwrap(source.range(of: "registerMonitor(matching: [.leftMouseUp]"))
        let keyUpStart = try XCTUnwrap(source.range(
            of: "matching: [.keyUp]",
            range: mouseUpStart.upperBound..<source.endIndex
        ))
        let mouseUpBlock = source[mouseUpStart.lowerBound..<keyUpStart.lowerBound]
        let mouseEnqueue = try XCTUnwrap(mouseUpBlock.range(of: "enqueueHandoff(for: .mouse)"))
        let mouseRelease = try XCTUnwrap(mouseUpBlock.range(of: "release(.mouse)"))
        let mouseTask = try XCTUnwrap(mouseUpBlock.range(of: "handoffScheduler { @MainActor"))

        XCTAssertLessThan(mouseEnqueue.lowerBound, mouseTask.lowerBound)
        XCTAssertLessThan(mouseRelease.lowerBound, mouseTask.lowerBound)
        XCTAssertTrue(mouseUpBlock.contains("defer {"))
        XCTAssertTrue(mouseUpBlock.contains("completeHandoff(for: .mouse)"))
        XCTAssertTrue(mouseUpBlock.contains("onCandidateSelection?(point)"))

        let flagsStart = try XCTUnwrap(source.range(
            of: "matching: [.flagsChanged]",
            range: keyUpStart.upperBound..<source.endIndex
        ))
        let keyUpBlock = source[keyUpStart.lowerBound..<flagsStart.lowerBound]
        let keyEnqueue = try XCTUnwrap(keyUpBlock.range(of: "enqueueHandoff(for: .keyboard)"))
        let keyTask = try XCTUnwrap(keyUpBlock.range(of: "handoffScheduler { @MainActor"))

        XCTAssertLessThan(keyEnqueue.lowerBound, keyTask.lowerBound)
        XCTAssertTrue(keyUpBlock.contains("defer {"))
        XCTAssertTrue(keyUpBlock.contains("completeHandoff(for: .keyboard)"))
        XCTAssertTrue(keyUpBlock.contains("onCandidateSelection?"))

        let pointerMonitorStart = try XCTUnwrap(source.range(
            of: "matching: [.scrollWheel",
            range: flagsStart.upperBound..<source.endIndex
        ))
        let flagsBlock = source[flagsStart.lowerBound..<pointerMonitorStart.lowerBound]
        XCTAssertTrue(flagsBlock.contains("begin(.keyboard)"))
        XCTAssertTrue(flagsBlock.contains("release(.keyboard)"))

        let stopStart = try XCTUnwrap(source.range(of: "\n    func stop()"))
        let pointerBlock = source[pointerMonitorStart.lowerBound..<stopStart.lowerBound]
        let mouseDownBegin = try XCTUnwrap(pointerBlock.range(of: "begin(.mouse)"))
        let pointerTask = try XCTUnwrap(pointerBlock.range(of: "handoffScheduler { @MainActor"))
        XCTAssertLessThan(mouseDownBegin.lowerBound, pointerTask.lowerBound)
    }

    func testDismissalTasksHoldInteractionHandoffsUntilCallbacksReturn() throws {
        let source = try monitorSource()
        let keyDownStart = try XCTUnwrap(source.range(of: "registerMonitor(matching: [.keyDown]"))
        let pointerStart = try XCTUnwrap(source.range(
            of: "matching: [.scrollWheel",
            range: keyDownStart.upperBound..<source.endIndex
        ))
        let keyDownBlock = source[keyDownStart.lowerBound..<pointerStart.lowerBound]
        let keyEnqueue = try XCTUnwrap(keyDownBlock.range(of: "enqueueHandoff(for: .keyboard)"))
        let keyTask = try XCTUnwrap(keyDownBlock.range(of: "handoffScheduler { @MainActor"))
        XCTAssertLessThan(keyEnqueue.lowerBound, keyTask.lowerBound)
        XCTAssertTrue(keyDownBlock.contains("defer {"))
        XCTAssertTrue(keyDownBlock.contains("completeHandoff(for: .keyboard)"))

        let stopStart = try XCTUnwrap(source.range(
            of: "\n    func stop()",
            range: pointerStart.upperBound..<source.endIndex
        ))
        let pointerBlock = source[pointerStart.lowerBound..<stopStart.lowerBound]
        let pointerEnqueue = try XCTUnwrap(pointerBlock.range(of: "enqueueHandoff(for: .mouse)"))
        let pointerTask = try XCTUnwrap(pointerBlock.range(of: "handoffScheduler { @MainActor"))
        XCTAssertLessThan(pointerEnqueue.lowerBound, pointerTask.lowerBound)
        XCTAssertTrue(pointerBlock.contains("defer {"))
        XCTAssertTrue(pointerBlock.contains("completeHandoff(for: .mouse)"))
    }

    func testStartReconcilesPhysicalButtonsAfterMonitorInstallation() throws {
        let source = try monitorSource()
        let start = try XCTUnwrap(source.range(of: "func start()"))
        let firstMonitor = try XCTUnwrap(source.range(
            of: "guard registerMonitor(matching:",
            range: start.upperBound..<source.endIndex
        ))
        let stop = try XCTUnwrap(source.range(
            of: "\n    func stop()",
            range: firstMonitor.upperBound..<source.endIndex
        ))
        let startBlock = source[start.lowerBound..<stop.lowerBound]
        let physicalSnapshot = try XCTUnwrap(startBlock.range(
            of: "let physicalState = physicalInteractionStateProvider()"
        ))
        let lastMonitor = try XCTUnwrap(startBlock.range(
            of: "guard registerMonitor(",
            options: .backwards
        ))

        XCTAssertTrue(startBlock.contains("isStarted = true"))
        XCTAssertEqual(startBlock.components(separatedBy: "guard registerMonitor(").count - 1, 5)
        XCTAssertTrue(startBlock.contains("let physicalState = physicalInteractionStateProvider()"))
        XCTAssertTrue(startBlock.contains("physicalState.isLeftMouseButtonPressed"))
        XCTAssertTrue(startBlock.contains("interactionTracker.begin(.mouse)"))
        XCTAssertTrue(startBlock.contains("physicalState.isShiftPressed"))
        XCTAssertTrue(startBlock.contains("interactionTracker.begin(.keyboard)"))
        XCTAssertTrue(source.contains("guard isStarted else { return false }"))
        XCTAssertLessThan(firstMonitor.lowerBound, physicalSnapshot.lowerBound)
        XCTAssertLessThan(lastMonitor.lowerBound, physicalSnapshot.lowerBound)
        XCTAssertFalse(startBlock.contains("as Any"))
    }

    func testDismissalMonitorIncludesRightMouseDown() throws {
        let source = try monitorSource()
        let dismissalMonitorStart = try XCTUnwrap(source.range(
            of: "matching: [.scrollWheel"
        ))
        let stopStart = try XCTUnwrap(source.range(
            of: "\n    func stop()",
            range: dismissalMonitorStart.upperBound..<source.endIndex
        ))
        let dismissalMonitorBlock = source[dismissalMonitorStart.lowerBound..<stopStart.lowerBound]

        XCTAssertTrue(dismissalMonitorBlock.contains("[.scrollWheel, .leftMouseDown, .rightMouseDown]"))
        XCTAssertFalse(dismissalMonitorBlock.contains(".rightMouseUp"))
    }

    func testMonitorNeverSynthesizesCopyOrMutatesPasteboard() throws {
        let source = try monitorSource()
        let forbiddenTokens = [
            "CGEvent(",
            ".post(tap:",
            "clearContents()",
            "setString(",
            "writeObjects(",
            "NSPasteboard.general.string"
        ]

        for token in forbiddenTokens {
            XCTAssertFalse(source.contains(token), "Selection monitor must not contain \(token)")
        }
    }

    func testStopOwnsCopyEventTapLifecycle() throws {
        let source = try monitorSource()
        let stopStart = try XCTUnwrap(source.range(of: "func stop()"))
        let nextMethod = try XCTUnwrap(source.range(
            of: "func recordPanelShown()",
            range: stopStart.upperBound..<source.endIndex
        ))
        let stopBlock = source[stopStart.lowerBound..<nextMethod.lowerBound]

        XCTAssertTrue(stopBlock.contains("copyEventTapStopper()"))
        XCTAssertTrue(stopBlock.contains("isStarted = false"))
        let stopped = try XCTUnwrap(stopBlock.range(of: "isStarted = false"))
        let copyStop = try XCTUnwrap(stopBlock.range(of: "copyEventTapStopper()"))
        XCTAssertLessThan(stopped.lowerBound, copyStop.lowerBound)
        XCTAssertTrue(stopBlock.contains("SelectionActionDiagnostics.resetEventAggregation()"))
    }

    func testSelectionEventDiagnosticsAreRateLimitedWithoutReadingContent() throws {
        let monitorSource = try monitorSource()
        let diagnosticsSource = try appSource(named: "SelectionActionDiagnostics.swift")
        let coordinatorSource = try appSource(named: "AppCoordinator.swift")

        XCTAssertTrue(diagnosticsSource.contains("SelectionActionDiagnosticRateLimiter"))
        XCTAssertTrue(diagnosticsSource.contains("static func logRateLimited"))
        XCTAssertTrue(diagnosticsSource.contains("static func resetEventAggregation"))
        XCTAssertTrue(monitorSource.contains(
            "SelectionActionDiagnostics.logRateLimited(\"candidate mouse selection\")"
        ))
        XCTAssertTrue(monitorSource.contains(
            "SelectionActionDiagnostics.logRateLimited(\"candidate keyboard selection\")"
        ))
        XCTAssertTrue(coordinatorSource.contains(
            "SelectionActionDiagnostics.logRateLimited(\"candidate sourceApp="
        ))
        XCTAssertTrue(coordinatorSource.contains(
            "SelectionActionDiagnostics.logRateLimited(\"effect scheduleRead"
        ))
        XCTAssertTrue(coordinatorSource.contains(
            "SelectionActionDiagnostics.logRateLimited(\"read result"
        ))
        XCTAssertFalse(diagnosticsSource.contains("event.characters"))
        XCTAssertFalse(diagnosticsSource.contains("NSPasteboard"))
    }

    private func monitorSource() throws -> String {
        try appSource(named: "SelectionActionMonitor.swift")
    }

    private func appSource(named filename: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/InkletApp")
            .appendingPathComponent(filename)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
