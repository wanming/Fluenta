import XCTest
@testable import InkletCore

final class SelectionReadPipelineTests: XCTestCase {
    @MainActor
    func testReadSelectedTextFollowsSourceValidatedFallbackTable() async {
        let sourceProcessIdentifier: pid_t = 42
        let mouseLocation = SelectionPoint(x: 24, y: 48)
        let scenarios: [Scenario] = [
            Scenario(
                name: "invalid source at start",
                validationResults: [false],
                accessibilityResult: .success("ignored"),
                forceSelectionMode: .menuCopyThenShortcut,
                clipboardResult: .success("ignored"),
                expectedResult: .emptySelection,
                expectedValidationCount: 1,
                expectedAccessibilityCount: 0,
                expectedClipboardCount: 0
            ),
            Scenario(
                name: "current AX success",
                validationResults: [true, true],
                accessibilityResult: .success("AX selection"),
                forceSelectionMode: .menuCopyThenShortcut,
                clipboardResult: .success("ignored"),
                expectedResult: .success("AX selection"),
                expectedValidationCount: 2,
                expectedAccessibilityCount: 1,
                expectedClipboardCount: 0
            ),
            Scenario(
                name: "stale AX success",
                validationResults: [true, false],
                accessibilityResult: .success("stale selection"),
                forceSelectionMode: .menuCopyThenShortcut,
                clipboardResult: .success("ignored"),
                expectedResult: .emptySelection,
                expectedValidationCount: 2,
                expectedAccessibilityCount: 1,
                expectedClipboardCount: 0
            ),
            Scenario(
                name: "AX permission denied",
                validationResults: [true],
                accessibilityResult: .permissionDenied,
                forceSelectionMode: .menuCopyThenShortcut,
                clipboardResult: .success("ignored"),
                expectedResult: .permissionDenied,
                expectedValidationCount: 1,
                expectedAccessibilityCount: 1,
                expectedClipboardCount: 0
            ),
            Scenario(
                name: "disabled fallback",
                validationResults: [true],
                accessibilityResult: .unsupported,
                forceSelectionMode: .disabled,
                clipboardResult: .success("ignored"),
                expectedResult: .unsupported,
                expectedValidationCount: 1,
                expectedAccessibilityCount: 1,
                expectedClipboardCount: 0
            ),
            Scenario(
                name: "clipboard success",
                validationResults: [true, true],
                accessibilityResult: .unsupported,
                forceSelectionMode: .menuCopyOnly,
                clipboardResult: .success("Copied selection"),
                expectedResult: .success("Copied selection"),
                expectedValidationCount: 2,
                expectedAccessibilityCount: 1,
                expectedClipboardCount: 1
            ),
            Scenario(
                name: "clipboard empty selection",
                validationResults: [true, true],
                accessibilityResult: .emptySelection,
                forceSelectionMode: .shortcutThenMenuCopy,
                clipboardResult: .emptySelection,
                expectedResult: .emptySelection,
                expectedValidationCount: 2,
                expectedAccessibilityCount: 1,
                expectedClipboardCount: 1
            ),
            Scenario(
                name: "clipboard unsupported preserves AX failure",
                validationResults: [true, true],
                accessibilityResult: .failed("AX"),
                forceSelectionMode: .menuCopyThenShortcut,
                clipboardResult: .unsupported,
                expectedResult: .failed("AX"),
                expectedValidationCount: 2,
                expectedAccessibilityCount: 1,
                expectedClipboardCount: 1
            ),
            Scenario(
                name: "stale source after unsupported clipboard fallback",
                validationResults: [true, false],
                accessibilityResult: .failed("AX"),
                forceSelectionMode: .menuCopyThenShortcut,
                clipboardResult: .unsupported,
                expectedResult: .emptySelection,
                expectedValidationCount: 2,
                expectedAccessibilityCount: 1,
                expectedClipboardCount: 1
            )
        ]

        for scenario in scenarios {
            let recorder = PipelineCallRecorder()
            let pipeline = SelectionReadPipeline(
                sourceValidator: { processIdentifier in
                    recorder.validatedProcessIdentifiers.append(processIdentifier)
                    let resultIndex = recorder.validatedProcessIdentifiers.count - 1
                    return scenario.validationResults[resultIndex]
                },
                accessibilityReader: { processIdentifier, location in
                    recorder.accessibilityArguments.append((processIdentifier, location))
                    return scenario.accessibilityResult
                },
                clipboardReader: { processIdentifier, forceSelectionMode in
                    recorder.clipboardArguments.append((processIdentifier, forceSelectionMode))
                    return scenario.clipboardResult
                }
            )

            let result = await pipeline.readSelectedText(
                sourceProcessIdentifier: sourceProcessIdentifier,
                mouseLocation: mouseLocation,
                forceSelectionMode: scenario.forceSelectionMode
            )

            XCTAssertEqual(result, scenario.expectedResult, scenario.name)
            XCTAssertEqual(
                recorder.validatedProcessIdentifiers.count,
                scenario.expectedValidationCount,
                scenario.name
            )
            XCTAssertTrue(
                recorder.validatedProcessIdentifiers.allSatisfy { $0 == sourceProcessIdentifier },
                scenario.name
            )
            XCTAssertEqual(recorder.accessibilityArguments.count, scenario.expectedAccessibilityCount, scenario.name)
            XCTAssertEqual(recorder.clipboardArguments.count, scenario.expectedClipboardCount, scenario.name)
            if scenario.expectedAccessibilityCount == 1 {
                XCTAssertEqual(recorder.accessibilityArguments.first?.0, sourceProcessIdentifier, scenario.name)
                XCTAssertEqual(recorder.accessibilityArguments.first?.1, mouseLocation, scenario.name)
            }
            if scenario.expectedClipboardCount == 1 {
                XCTAssertEqual(recorder.clipboardArguments.first?.0, sourceProcessIdentifier, scenario.name)
                XCTAssertEqual(recorder.clipboardArguments.first?.1, scenario.forceSelectionMode, scenario.name)
            }
        }
    }

    @MainActor
    func testReadSelectedTextRejectsClipboardSuccessWhenSourceChangesDuringRead() async {
        let sourceProcessIdentifier: pid_t = 42
        let recorder = PipelineCallRecorder()
        let pipeline = SelectionReadPipeline(
            sourceValidator: { processIdentifier in
                recorder.validatedProcessIdentifiers.append(processIdentifier)
                return recorder.sourceIsCurrent
            },
            accessibilityReader: { processIdentifier, location in
                recorder.accessibilityArguments.append((processIdentifier, location))
                return .unsupported
            },
            clipboardReader: { processIdentifier, forceSelectionMode in
                recorder.clipboardArguments.append((processIdentifier, forceSelectionMode))
                recorder.sourceIsCurrent = false
                return .success("old app text")
            }
        )

        let result = await pipeline.readSelectedText(
            sourceProcessIdentifier: sourceProcessIdentifier,
            mouseLocation: nil,
            forceSelectionMode: .menuCopyOnly
        )

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(recorder.validatedProcessIdentifiers, [sourceProcessIdentifier, sourceProcessIdentifier])
        XCTAssertEqual(recorder.accessibilityArguments.count, 1)
        XCTAssertEqual(recorder.clipboardArguments.count, 1)
    }
}

private struct Scenario: Sendable {
    let name: String
    let validationResults: [Bool]
    let accessibilityResult: SelectedTextReadResult
    let forceSelectionMode: SelectionForceSelectionMode
    let clipboardResult: SelectedTextReadResult
    let expectedResult: SelectedTextReadResult
    let expectedValidationCount: Int
    let expectedAccessibilityCount: Int
    let expectedClipboardCount: Int
}

@MainActor
private final class PipelineCallRecorder {
    var sourceIsCurrent = true
    var validatedProcessIdentifiers: [pid_t] = []
    var accessibilityArguments: [(pid_t, SelectionPoint?)] = []
    var clipboardArguments: [(pid_t, SelectionForceSelectionMode)] = []
}
