import XCTest

final class SelectionActionMonitorSourceTests: XCTestCase {
    func testCandidateMouseUpMonitorDoesNotObserveRightMouseUp() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/SelectionActionMonitor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let mouseUpMonitorStart = try XCTUnwrap(source.range(
            of: "NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp"
        ))
        let keyUpMonitorStart = try XCTUnwrap(source.range(
            of: "NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]",
            range: mouseUpMonitorStart.upperBound..<source.endIndex
        ))
        let mouseUpMonitorBlock = source[mouseUpMonitorStart.lowerBound..<keyUpMonitorStart.lowerBound]

        XCTAssertTrue(mouseUpMonitorBlock.contains(".leftMouseUp"))
        XCTAssertFalse(mouseUpMonitorBlock.contains(".rightMouseUp"))
    }
}
