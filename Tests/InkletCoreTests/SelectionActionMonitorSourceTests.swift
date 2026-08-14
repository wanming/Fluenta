import XCTest

final class SelectionActionMonitorSourceTests: XCTestCase {
    func testCopyTapCallbackIsForwardedSynchronouslyWithoutTaskHop() throws {
        let source = try monitorSource()
        let startRange = try XCTUnwrap(source.range(of: "func start()"))
        let firstMonitorRange = try XCTUnwrap(source.range(
            of: "NSEvent.addGlobalMonitorForEvents",
            range: startRange.upperBound..<source.endIndex
        ))
        let startBlock = source[startRange.lowerBound..<firstMonitorRange.lowerBound]

        XCTAssertTrue(source.contains("var onCopyTrigger: ((SelectionCopyEventTap.Trigger) -> Void)?"))
        XCTAssertTrue(source.contains("private let copyEventTap: SelectionCopyEventTap"))
        XCTAssertTrue(startBlock.contains("copyEventTap.start { [weak self] trigger in"))
        XCTAssertTrue(startBlock.contains("self?.onCopyTrigger?(trigger)"))
        XCTAssertFalse(startBlock.contains("Task"))
        XCTAssertFalse(source.contains("SelectionCopyTriggerPolicy"))
        XCTAssertFalse(source.contains("NSPasteboard.general.changeCount"))
    }

    func testGlobalKeyDownCopyOnlyBypassesDismissal() throws {
        let source = try monitorSource()
        let keyDownMonitorStart = try XCTUnwrap(source.range(
            of: "NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]"
        ))
        let dismissalMonitorStart = try XCTUnwrap(source.range(
            of: "NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel",
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
            of: "NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp"
        ))
        let keyUpMonitorStart = try XCTUnwrap(source.range(
            of: "NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]",
            range: mouseUpMonitorStart.upperBound..<source.endIndex
        ))
        let mouseUpMonitorBlock = source[mouseUpMonitorStart.lowerBound..<keyUpMonitorStart.lowerBound]

        XCTAssertTrue(mouseUpMonitorBlock.contains("matching: [.leftMouseUp])"))
        XCTAssertFalse(mouseUpMonitorBlock.contains(".rightMouseDown"))
        XCTAssertFalse(mouseUpMonitorBlock.contains(".rightMouseUp"))
    }

    func testShiftKeyUpCandidateMonitorRemainsInstalled() throws {
        let source = try monitorSource()
        let keyUpMonitorStart = try XCTUnwrap(source.range(
            of: "NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]"
        ))
        let keyDownMonitorStart = try XCTUnwrap(source.range(
            of: "NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]",
            range: keyUpMonitorStart.upperBound..<source.endIndex
        ))
        let keyUpMonitorBlock = source[keyUpMonitorStart.lowerBound..<keyDownMonitorStart.lowerBound]

        XCTAssertTrue(keyUpMonitorBlock.contains("modifiers.contains(.shift)"))
        XCTAssertTrue(keyUpMonitorBlock.contains("onCandidateSelection?"))
    }

    func testDismissalMonitorIncludesRightMouseDown() throws {
        let source = try monitorSource()
        let dismissalMonitorStart = try XCTUnwrap(source.range(
            of: "NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel"
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

        XCTAssertTrue(stopBlock.contains("copyEventTap.stop()"))
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
