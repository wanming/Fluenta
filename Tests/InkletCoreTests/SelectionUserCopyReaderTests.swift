import AppKit
import XCTest
@testable import InkletCore

final class SelectionUserCopyReaderTests: XCTestCase {
    @MainActor
    func testAlreadyCanceledParentReturnsEmptyWithoutPollingOrMutatingPasteboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("existing clipboard", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        var didDelay = false
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in true },
            delayProvider: { _ in didDelay = true }
        )
        let readTask = Task { @MainActor in
            await Task.yield()
            return await reader.readCopiedText(
                sourceProcessIdentifier: 42,
                after: initialChangeCount
            )
        }

        readTask.cancel()
        let result = await readTask.value

        XCTAssertEqual(result, .emptySelection)
        XCTAssertFalse(didDelay)
        XCTAssertEqual(pasteboard.changeCount, initialChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard")
    }

    @MainActor
    func testReadsTrimmedTextAfterUserCopyChangesPasteboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first copy", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        var expectedChangeCount = initialChangeCount
        var delayCount = 0
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 3,
            sourceProcessValidator: { $0 == 42 },
            delayProvider: { _ in
                delayCount += 1
                guard delayCount == 1 else { return }
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("  second copy\n", forType: .string))
                expectedChangeCount = pasteboard.changeCount
            }
        )

        let result = await reader.readCopiedText(
            sourceProcessIdentifier: 42,
            after: initialChangeCount
        )

        XCTAssertEqual(result, .success("second copy"))
        XCTAssertEqual(delayCount, 1)
        XCTAssertEqual(pasteboard.changeCount, expectedChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "  second copy\n")
    }

    @MainActor
    func testReadsCopyThatCompletedBeforeReaderStarted() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first copy", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("second copy", forType: .string))
        var didDelay = false
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { $0 == 42 },
            delayProvider: { _ in didDelay = true }
        )

        let result = await reader.readCopiedText(
            sourceProcessIdentifier: 42,
            after: initialChangeCount
        )

        XCTAssertEqual(result, .success("second copy"))
        XCTAssertFalse(didDelay)
    }

    @MainActor
    func testReturnsEmptyWhenCandidateGenerationChangesDuringSourceValidation() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first copy", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("candidate copy", forType: .string))
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("later unrelated copy", forType: .string))
                return true
            }
        )

        let result = await reader.readCopiedText(
            sourceProcessIdentifier: 42,
            after: initialChangeCount
        )

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "later unrelated copy")
    }

    @MainActor
    func testReturnsEmptyWhenCandidateGenerationChangesDuringStringRead() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first copy", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("candidate copy", forType: .string))
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in true },
            pasteboardStringReader: { pasteboard in
                let candidate = pasteboard.string(forType: .string)
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("later unrelated copy", forType: .string))
                return candidate
            }
        )

        let result = await reader.readCopiedText(
            sourceProcessIdentifier: 42,
            after: initialChangeCount
        )

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "later unrelated copy")
    }

    @MainActor
    func testObservesCopyAtExactPollingDeadline() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first copy", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        var delays: [UInt64] = []
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 2,
            pollTimeoutNanoseconds: 3,
            sourceProcessValidator: { _ in true },
            delayProvider: { delay in
                delays.append(delay)
                guard delays.count == 2 else { return }
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("deadline copy", forType: .string))
            }
        )

        let result = await reader.readCopiedText(
            sourceProcessIdentifier: 42,
            after: initialChangeCount
        )

        XCTAssertEqual(result, .success("deadline copy"))
        XCTAssertEqual(delays, [2, 1])
    }

    @MainActor
    func testZeroPollIntervalStillTerminatesAtDeadline() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("existing clipboard", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        var delays: [UInt64] = []
        var cancelRead: (() -> Void)?
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 0,
            pollTimeoutNanoseconds: 3,
            sourceProcessValidator: { _ in true },
            delayProvider: { delay in
                delays.append(delay)
                if delays.count == 4 {
                    cancelRead?()
                }
            }
        )
        let readTask = Task { @MainActor in
            await reader.readCopiedText(
                sourceProcessIdentifier: 42,
                after: initialChangeCount
            )
        }
        cancelRead = { readTask.cancel() }

        let result = await readTask.value

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(delays, [1, 1, 1])
    }

    @MainActor
    func testReturnsEmptyWhenPasteboardNeverChangesWithoutMutatingIt() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("existing clipboard", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 3,
            sourceProcessValidator: { _ in true },
            delayProvider: { _ in }
        )

        let result = await reader.readCopiedText(
            sourceProcessIdentifier: 42,
            after: initialChangeCount
        )

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(pasteboard.changeCount, initialChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard")
    }

    @MainActor
    func testReturnsEmptyWhenSourceBecomesInvalidWithoutRestoringChangedPasteboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first copy", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        var expectedChangeCount = initialChangeCount
        var isSourceValid = true
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 3,
            sourceProcessValidator: { _ in isSourceValid },
            delayProvider: { _ in
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("external current value", forType: .string))
                expectedChangeCount = pasteboard.changeCount
                isSourceValid = false
            }
        )

        let result = await reader.readCopiedText(
            sourceProcessIdentifier: 42,
            after: initialChangeCount
        )

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(pasteboard.changeCount, expectedChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "external current value")
    }

    @MainActor
    func testParentCancellationReturnsEmptyWithoutRestoringExternalPasteboardChange() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first copy", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        let pollingStarted = expectation(description: "passive polling started")
        var expectedChangeCount = initialChangeCount
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 3,
            sourceProcessValidator: { _ in true },
            delayProvider: { _ in
                pollingStarted.fulfill()
                while !Task.isCancelled {
                    await Task.yield()
                }
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("external current value", forType: .string))
                expectedChangeCount = pasteboard.changeCount
            }
        )
        let readTask = Task { @MainActor in
            await reader.readCopiedText(
                sourceProcessIdentifier: 42,
                after: initialChangeCount
            )
        }
        await fulfillment(of: [pollingStarted], timeout: 1)

        readTask.cancel()
        let result = await readTask.value

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(pasteboard.changeCount, expectedChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "external current value")
    }

    @MainActor
    func testCancellationDuringFinalValidationReturnsEmptyWithoutRestoringChangedPasteboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first copy", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        var expectedChangeCount = initialChangeCount
        var cancelRead: (() -> Void)?
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 3,
            sourceProcessValidator: { _ in
                cancelRead?()
                return true
            },
            delayProvider: { _ in
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("external current value", forType: .string))
                expectedChangeCount = pasteboard.changeCount
            }
        )
        let readTask = Task { @MainActor in
            await reader.readCopiedText(
                sourceProcessIdentifier: 42,
                after: initialChangeCount
            )
        }
        cancelRead = { readTask.cancel() }

        let result = await readTask.value

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(pasteboard.changeCount, expectedChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "external current value")
    }

    @MainActor
    func testChangedWhitespaceTextReturnsEmptyWithoutMutatingIt() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("first copy", forType: .string))
        let initialChangeCount = pasteboard.changeCount
        var expectedChangeCount = initialChangeCount
        let reader = SelectionUserCopyReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 3,
            sourceProcessValidator: { _ in true },
            delayProvider: { _ in
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString(" \n\t ", forType: .string))
                expectedChangeCount = pasteboard.changeCount
            }
        )

        let result = await reader.readCopiedText(
            sourceProcessIdentifier: 42,
            after: initialChangeCount
        )

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(pasteboard.changeCount, expectedChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), " \n\t ")
    }

    func testReaderSourceContainsNoPasteboardMutationOrCopySynthesis() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent(
            "Sources/InkletCore/SelectionUserCopyReader.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let forbiddenTokens = [
            "clearContents",
            "setString",
            "writeObjects",
            "ClipboardService",
            "CGEvent",
            "NSEvent",
            ".post(",
            "copyMenu",
            "sendCopy",
            "readSelectedText",
            "snapshot",
            "restore"
        ]

        for token in forbiddenTokens {
            XCTAssertFalse(source.contains(token), "Passive reader must not contain \(token)")
        }
    }
}
