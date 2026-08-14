import XCTest

final class SelectionActionMonitorSourceTests: XCTestCase {
    func testCopyGestureWiringUsesLifecycleRepeatAndEventProvenance() throws {
        let monitorSource = try source(named: "SelectionActionMonitor.swift")

        XCTAssertTrue(monitorSource.contains("var onCopyTrigger: ((SelectionPoint, Int, pid_t) -> Void)?"))
        XCTAssertTrue(monitorSource.contains("event.keyCode == 8"))
        XCTAssertTrue(monitorSource.contains("event.isARepeat"))
        XCTAssertTrue(monitorSource.contains("NSPasteboard.general.changeCount"))
        XCTAssertTrue(monitorSource.contains(".eventSourceUserData"))
        XCTAssertTrue(monitorSource.contains(".eventSourceUnixProcessID"))
        XCTAssertTrue(monitorSource.contains("SelectionClipboardReader.generatedCopyEventUserData"))
        XCTAssertTrue(monitorSource.contains("copyTriggerPolicy.recordKeyDown"))
        XCTAssertTrue(monitorSource.contains("copyTriggerPolicy.recordKeyUp"))
        XCTAssertTrue(monitorSource.contains("copyTriggerPolicy.reset()"))
        XCTAssertTrue(monitorSource.contains("SelectionActionDiagnostics.resetCopyEventAggregation()"))
        XCTAssertFalse(monitorSource.contains("event.characters"))
    }

    func testCopyDiagnosticsAreRateLimitedAndDoNotReadContent() throws {
        let diagnosticsSource = try source(named: "SelectionActionDiagnostics.swift")

        XCTAssertTrue(diagnosticsSource.contains("static func logCopyEvent"))
        XCTAssertTrue(diagnosticsSource.contains("suppressedCopyEventCount"))
        XCTAssertTrue(diagnosticsSource.contains("static func resetCopyEventAggregation"))
        XCTAssertFalse(diagnosticsSource.contains("event.characters"))
        XCTAssertFalse(diagnosticsSource.contains("NSPasteboard"))
    }

    private func source(named filename: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("InkletApp")
            .appendingPathComponent(filename)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
