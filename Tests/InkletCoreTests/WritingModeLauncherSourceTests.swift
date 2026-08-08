import XCTest
@testable import InkletCore

final class WritingModeLauncherSourceTests: XCTestCase {
    func testPopoverViewModelOwnsLauncherAndSessionState() throws {
        let source = try popoverSource()

        XCTAssertTrue(source.contains("@Published private(set) var modePickerState: WritingModePickerState"))
        XCTAssertTrue(source.contains("@Published private(set) var popoverSession: WritingPopoverSessionState"))
        XCTAssertTrue(source.contains("@Published private(set) var modeSearchFocusRevision = 0"))
        XCTAssertTrue(source.contains("@Published private(set) var modes: [PromptMode]"))
        XCTAssertTrue(source.contains("private let writingModePreferenceStore: WritingModePreferenceStore"))
        XCTAssertTrue(source.contains("func commitHighlightedMode()"))
        XCTAssertTrue(source.contains("func returnToModePicker()"))
        XCTAssertTrue(source.contains("writingModePreferenceStore.saveLastModeID"))
        XCTAssertFalse(source.contains("@Published var selectedModeID"))
        XCTAssertFalse(source.contains("@Published var openRevision"))
    }

    func testPopoverViewModelTracksAndPreservesStaleResults() throws {
        let source = try popoverSource()

        XCTAssertTrue(source.contains("var isResultStale: Bool"))
        XCTAssertTrue(source.contains("let preservesExistingResult = isResultStale"))
        XCTAssertTrue(source.contains("if !preservesExistingResult"))
        XCTAssertTrue(source.contains("recordResult(modeID: transformationModeID)"))
    }

    func testPopoverViewModelCanCancelTransformationWithoutClosingEditor() throws {
        let source = try popoverSource()

        XCTAssertTrue(source.contains("cancelTransformationAndStayInEditor"))
    }

    func testEscapeFromModePickerClosesDirectly() throws {
        let source = try popoverSource()
        let pickerEscapeStart = try XCTUnwrap(source.range(of: "if route == .modePicker {"))
        let editorEscapeStart = try XCTUnwrap(source.range(
            of: "\n        if !resultText.isEmpty {",
            range: pickerEscapeStart.upperBound..<source.endIndex
        ))
        let pickerEscapeBlock = source[pickerEscapeStart.lowerBound..<editorEscapeStart.lowerBound]

        XCTAssertTrue(pickerEscapeBlock.contains("handle(actions: stateMachine.send(.close))"))
        XCTAssertFalse(pickerEscapeBlock.contains("stateMachine.send(.escape)"))
    }

    func testPreservedFailureAndCancellationRestoreStateFromVisibleContent() throws {
        let source = try popoverSource()
        let transformationStart = try XCTUnwrap(source.range(of: "private func startTransformation"))
        let failureStart = try XCTUnwrap(source.range(
            of: "} catch {",
            range: transformationStart.upperBound..<source.endIndex
        ))
        let cancellationStart = try XCTUnwrap(source.range(
            of: "private func cancelTransformationAndStayInEditor",
            range: failureStart.upperBound..<source.endIndex
        ))
        let mutationHelperStart = try XCTUnwrap(source.range(
            of: "private func mutateModePickerState",
            range: cancellationStart.upperBound..<source.endIndex
        ))
        let failureBlock = source[failureStart.lowerBound..<cancellationStart.lowerBound]
        let cancellationBlock = source[cancellationStart.lowerBound..<mutationHelperStart.lowerBound]

        XCTAssertTrue(source.contains("private func synchronizeStateMachineWithVisibleContent()"))
        XCTAssertTrue(source.contains(".previewingResult(source: sourceText, result: resultText)"))
        XCTAssertTrue(source.contains(".editingSource(source: sourceText, errorMessage: nil)"))
        XCTAssertTrue(failureBlock.contains("if preservesExistingResult"))
        XCTAssertTrue(failureBlock.contains("\n                    synchronizeStateMachineWithVisibleContent()\n"))
        XCTAssertTrue(cancellationBlock.contains("\n        synchronizeStateMachineWithVisibleContent()\n"))
    }

    func testReselectingPreservedResultsModeMakesSubmitInsertVisibleResult() {
        let source = "Draft"
        let oldResult = "Old result"
        let oldModeID = "old-mode"
        var session = WritingPopoverSessionState(
            selectedModeID: oldModeID,
            route: .editor
        )
        session.recordResult(modeID: oldModeID)
        session.enterEditor(modeID: "new-mode")

        let failedMachine = PopoverStateMachine(state: .transforming(source: source))
        XCTAssertEqual(
            failedMachine.send(.transformationFailed(message: "Offline")),
            [.showError("Offline"), .focusSourceInput]
        )

        let restoredMachine = PopoverStateMachine(
            state: .previewingResult(source: source, result: oldResult)
        )
        session.enterEditor(modeID: oldModeID)

        XCTAssertFalse(session.isResultStale)
        let actions = restoredMachine.send(.submit)
        XCTAssertEqual(actions, [.insertText(oldResult)])
        XCTAssertFalse(actions.contains(.startTransformation(source: source)))
    }

    func testRetryingWhileResultIsStillStaleStartsTransformation() {
        let source = "Draft"
        let oldResult = "Old result"
        var session = WritingPopoverSessionState(
            selectedModeID: "old-mode",
            route: .editor
        )
        session.recordResult(modeID: "old-mode")
        session.enterEditor(modeID: "new-mode")
        let restoredMachine = PopoverStateMachine(
            state: .previewingResult(source: source, result: oldResult)
        )

        XCTAssertTrue(session.isResultStale)
        XCTAssertEqual(restoredMachine.send(.sourceChanged(source)), [])
        let actions = restoredMachine.send(.submit)
        XCTAssertEqual(actions, [.startTransformation(source: source)])
        XCTAssertFalse(actions.contains(.insertText(oldResult)))
    }

    private func popoverSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/InkletPopoverView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
