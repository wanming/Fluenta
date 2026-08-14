import AppKit
import XCTest
@testable import InkletCore

final class SelectionClipboardReaderTests: XCTestCase {
    @MainActor
    func testMenuActionReadsChangedPasteboardAndRestoresOriginalItems() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let customType = NSPasteboard.PasteboardType("com.inklet.test.selection.binary")
        let secondCustomType = NSPasteboard.PasteboardType("com.inklet.test.selection.second-binary")
        let customData = Data([0x11, 0x22, 0x33])
        let secondCustomData = Data([0x44, 0x55, 0x66])
        let originalItem = NSPasteboardItem()
        XCTAssertTrue(originalItem.setString("Original clipboard", forType: .string))
        XCTAssertTrue(originalItem.setData(customData, forType: customType))
        let secondOriginalItem = NSPasteboardItem()
        XCTAssertTrue(secondOriginalItem.setData(secondCustomData, forType: secondCustomType))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([originalItem, secondOriginalItem]))

        var requestedProcessIdentifier: pid_t?
        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { processIdentifier in
                requestedProcessIdentifier = processIdentifier
                pasteboard.clearContents()
                pasteboard.setString("  copied selection  ", forType: .string)
                return .performed
            },
            copyShortcutSender: { _ in didSendShortcut = true },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .menuCopyThenShortcut
        )

        XCTAssertEqual(result, .success("copied selection"))
        XCTAssertEqual(requestedProcessIdentifier, 42)
        XCTAssertFalse(didSendShortcut)

        let restoredItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restoredItems.count, 2)
        XCTAssertEqual(restoredItems[0].string(forType: .string), "Original clipboard")
        XCTAssertEqual(restoredItems[0].data(forType: customType), customData)
        XCTAssertEqual(restoredItems[1].data(forType: secondCustomType), secondCustomData)
    }

    @MainActor
    func testNoCopyMenuItemFallsBackToShortcutCopy() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in .noMenuItem },
            copyShortcutSender: { _ in
                didSendShortcut = true
                pasteboard.clearContents()
                pasteboard.setString("Shortcut selection", forType: .string)
            },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .menuCopyThenShortcut
        )

        XCTAssertEqual(result, .success("Shortcut selection"))
        XCTAssertTrue(didSendShortcut)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testDisabledCopyMenuItemDoesNotSendShortcut() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in .disabled },
            copyShortcutSender: { _ in didSendShortcut = true },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .menuCopyThenShortcut
        )

        XCTAssertEqual(result, .emptySelection)
        XCTAssertFalse(didSendShortcut)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testDisabledForceSelectionDoesNotUseMenuOrShortcutCopy() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        var didRequestMenu = false
        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in
                didRequestMenu = true
                return .performed
            },
            copyShortcutSender: { _ in didSendShortcut = true },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .disabled
        )

        XCTAssertEqual(result, .unsupported)
        XCTAssertFalse(didRequestMenu)
        XCTAssertFalse(didSendShortcut)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testMenuCopyOnlyDoesNotFallbackToShortcutWhenCopyMenuIsMissing() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in .noMenuItem },
            copyShortcutSender: { _ in didSendShortcut = true },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .menuCopyOnly
        )

        XCTAssertEqual(result, .unsupported)
        XCTAssertFalse(didSendShortcut)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testShortcutFirstFallsBackToMenuActionWhenShortcutDoesNotProduceText() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        var didSendShortcut = false
        var didRequestMenu = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in
                didRequestMenu = true
                pasteboard.clearContents()
                pasteboard.setString("Menu selection", forType: .string)
                return .performed
            },
            copyShortcutSender: { _ in didSendShortcut = true },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .shortcutThenMenuCopy
        )

        XCTAssertEqual(result, .success("Menu selection"))
        XCTAssertTrue(didSendShortcut)
        XCTAssertTrue(didRequestMenu)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testInactiveSourceReturnsEmptyWithoutMenuOrShortcut() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        var didRequestMenu = false
        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in false },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in
                didRequestMenu = true
                return .performed
            },
            copyShortcutSender: { _ in didSendShortcut = true },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .menuCopyThenShortcut
        )

        XCTAssertEqual(result, .emptySelection)
        XCTAssertFalse(didRequestMenu)
        XCTAssertFalse(didSendShortcut)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testExternalClipboardChangeAfterOwnedCopyIsNotOverwritten() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        var validationCount = 0
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 2,
            sourceProcessValidator: { _ in
                validationCount += 1
                if validationCount == 2 {
                    pasteboard.clearContents()
                    pasteboard.setString("new user value", forType: .string)
                }
                return true
            },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in
                pasteboard.clearContents()
                pasteboard.setString("Owned selection", forType: .string)
                return .performed
            },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .menuCopyOnly
        )

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "new user value")
    }

    @MainActor
    func testCancellationAfterOwnedCopyRestoresOriginalAndReturnsEmpty() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)
        let pollingStarted = expectation(description: "owned empty copy entered polling")
        var didStartPolling = false

        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1_000_000_000,
            pollTimeoutNanoseconds: 60_000_000_000,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in
                pasteboard.clearContents()
                return .performed
            },
            delayProvider: { _ in
                guard !didStartPolling else { return }
                didStartPolling = true
                pollingStarted.fulfill()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            },
            shortcutReadWrapper: { operation in await operation() }
        )

        let readTask = Task { @MainActor in
            await reader.readSelectedText(
                sourceProcessIdentifier: 42,
                forceSelectionMode: .menuCopyOnly
            )
        }
        await fulfillment(of: [pollingStarted], timeout: 1)

        readTask.cancel()
        let result = await readTask.value

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testUserCopyHandoffWithoutActiveReadCapturesBoundaryAndFinishesNoActiveRead() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Existing clipboard", forType: .string))
        let reader = SelectionClipboardReader(pasteboard: pasteboard)

        let handoff = reader.beginUserCopyHandoff()
        let outcome = await reader.finishUserCopyHandoff(handoff)

        XCTAssertEqual(handoff.boundaryChangeCount, pasteboard.changeCount)
        XCTAssertEqual(outcome, .noActiveRead)
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing clipboard")
    }

    @MainActor
    func testUserCopyBeforeHandoffFinishIsNeverOverwrittenByRestoration() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Original clipboard", forType: .string))
        let pollingStarted = expectation(description: "owned copy entered polling")
        var didStartPolling = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 100,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in
                pasteboard.clearContents()
                return .performed
            },
            delayProvider: { _ in
                guard !didStartPolling else { return }
                didStartPolling = true
                pollingStarted.fulfill()
                while !Task.isCancelled {
                    await Task.yield()
                }
            },
            shortcutReadWrapper: { operation in await operation() }
        )
        let readTask = Task { @MainActor in
            await reader.readSelectedText(
                sourceProcessIdentifier: 42,
                forceSelectionMode: .menuCopyOnly
            )
        }
        await fulfillment(of: [pollingStarted], timeout: 1)

        let handoff = reader.beginUserCopyHandoff()
        XCTAssertEqual(handoff.boundaryChangeCount, pasteboard.changeCount)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Physical user copy", forType: .string))
        let outcome = await reader.finishUserCopyHandoff(handoff)
        let readResult = await readTask.value

        XCTAssertEqual(outcome, .restorationRelinquished)
        XCTAssertEqual(readResult, .emptySelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "Physical user copy")
    }

    @MainActor
    func testUserCopyAfterHandoffFinishIsNeverOverwrittenByOldDefer() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Original clipboard", forType: .string))
        let pollingStarted = expectation(description: "owned copy entered polling")
        var didStartPolling = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 100,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in
                pasteboard.clearContents()
                return .performed
            },
            delayProvider: { _ in
                guard !didStartPolling else { return }
                didStartPolling = true
                pollingStarted.fulfill()
                while !Task.isCancelled {
                    await Task.yield()
                }
            },
            shortcutReadWrapper: { operation in await operation() }
        )
        let readTask = Task { @MainActor in
            await reader.readSelectedText(
                sourceProcessIdentifier: 42,
                forceSelectionMode: .menuCopyOnly
            )
        }
        await fulfillment(of: [pollingStarted], timeout: 1)

        let handoff = reader.beginUserCopyHandoff()
        let outcome = await reader.finishUserCopyHandoff(handoff)
        let readResult = await readTask.value
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Physical user copy", forType: .string))

        XCTAssertEqual(outcome, .restorationRelinquished)
        XCTAssertEqual(readResult, .emptySelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "Physical user copy")
    }

    @MainActor
    func testHandoffCompletesActiveReadThatHasNotMutatedPasteboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Original clipboard", forType: .string))
        let wrapperStarted = expectation(description: "shortcut wrapper started before transaction")
        let state = PreTransactionHandoffTestState()
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyShortcutSender: { _ in
                state.didSendShortcut = true
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("Late synthetic copy", forType: .string))
            },
            shortcutReadWrapper: { operation in
                wrapperStarted.fulfill()
                while !state.releaseWrapper {
                    await Task.yield()
                }
                return await operation()
            }
        )
        let readTask = Task { @MainActor in
            await reader.readSelectedText(
                sourceProcessIdentifier: 42,
                forceSelectionMode: .shortcutThenMenuCopy
            )
        }
        await fulfillment(of: [wrapperStarted], timeout: 1)

        let handoff = reader.beginUserCopyHandoff()
        state.releaseWrapper = true
        let outcome = await reader.finishUserCopyHandoff(handoff)
        let readResult = await readTask.value

        XCTAssertEqual(outcome, .completedWithoutPasteboardMutation)
        XCTAssertEqual(readResult, .emptySelection)
        XCTAssertFalse(state.didSendShortcut)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testHandoffReportsUnobservedShortcutDispatchBeforeDelayedPasteboardMutation() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Original clipboard", forType: .string))
        let pollingStarted = expectation(description: "shortcut dispatch entered polling")
        var didStartPolling = false
        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 100,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyShortcutSender: { _ in
                didSendShortcut = true
            },
            delayProvider: { _ in
                guard !didStartPolling else { return }
                didStartPolling = true
                pollingStarted.fulfill()
                while !Task.isCancelled {
                    await Task.yield()
                }
            },
            shortcutReadWrapper: { operation in await operation() }
        )
        let readTask = Task { @MainActor in
            await reader.readSelectedText(
                sourceProcessIdentifier: 42,
                forceSelectionMode: .shortcutThenMenuCopy
            )
        }
        await fulfillment(of: [pollingStarted], timeout: 1)

        let handoff = reader.beginUserCopyHandoff()
        let outcome = await reader.finishUserCopyHandoff(handoff)
        let readResult = await readTask.value
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Delayed synthetic copy", forType: .string))

        XCTAssertTrue(didSendShortcut)
        XCTAssertEqual(outcome, .unobservedSyntheticAction)
        XCTAssertEqual(readResult, .emptySelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "Delayed synthetic copy")
    }

    @MainActor
    func testHandoffReportsUnobservedPerformedMenuActionBeforeDelayedPasteboardMutation() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Original clipboard", forType: .string))
        let pollingStarted = expectation(description: "menu action entered polling")
        var didStartPolling = false
        var didPerformMenuAction = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 100,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in
                didPerformMenuAction = true
                return .performed
            },
            delayProvider: { _ in
                guard !didStartPolling else { return }
                didStartPolling = true
                pollingStarted.fulfill()
                while !Task.isCancelled {
                    await Task.yield()
                }
            },
            shortcutReadWrapper: { operation in await operation() }
        )
        let readTask = Task { @MainActor in
            await reader.readSelectedText(
                sourceProcessIdentifier: 42,
                forceSelectionMode: .menuCopyOnly
            )
        }
        await fulfillment(of: [pollingStarted], timeout: 1)

        let handoff = reader.beginUserCopyHandoff()
        let outcome = await reader.finishUserCopyHandoff(handoff)
        let readResult = await readTask.value
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Delayed synthetic copy", forType: .string))

        XCTAssertTrue(didPerformMenuAction)
        XCTAssertEqual(outcome, .unobservedSyntheticAction)
        XCTAssertEqual(readResult, .emptySelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "Delayed synthetic copy")
    }

    @MainActor
    func testHandoffInvalidatesReadWaitingBehindActiveCleanup() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Original clipboard", forType: .string))
        let firstReadPolling = expectation(description: "first read entered polling")
        let secondCallerStarted = expectation(description: "second caller started")
        let state = PendingHandoffTestState()
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 100,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { processIdentifier in
                state.actionProcessIdentifiers.append(processIdentifier)
                pasteboard.clearContents()
                return .performed
            },
            delayProvider: { _ in
                firstReadPolling.fulfill()
                while !state.releaseFirstRead {
                    state.firstReadObservedCancellation = Task.isCancelled
                    await Task.yield()
                }
            },
            shortcutReadWrapper: { operation in await operation() }
        )
        let firstReadTask = Task { @MainActor in
            await reader.readSelectedText(
                sourceProcessIdentifier: 101,
                forceSelectionMode: .menuCopyOnly
            )
        }
        await fulfillment(of: [firstReadPolling], timeout: 1)
        let secondReadTask = Task { @MainActor in
            secondCallerStarted.fulfill()
            return await reader.readSelectedText(
                sourceProcessIdentifier: 202,
                forceSelectionMode: .menuCopyOnly
            )
        }
        await fulfillment(of: [secondCallerStarted], timeout: 1)
        while !state.firstReadObservedCancellation {
            await Task.yield()
        }

        let handoff = reader.beginUserCopyHandoff()
        state.releaseFirstRead = true
        let outcome = await reader.finishUserCopyHandoff(handoff)
        let firstResult = await firstReadTask.value
        let secondResult = await secondReadTask.value

        XCTAssertEqual(outcome, .restorationRelinquished)
        XCTAssertEqual(firstResult, .emptySelection)
        XCTAssertEqual(secondResult, .emptySelection)
        XCTAssertEqual(state.actionProcessIdentifiers, [101])
    }

    @MainActor
    func testSyntheticCopyShortcutEventsCarryUserDataMarker() throws {
        let eventSource = try XCTUnwrap(CGEventSource(stateID: .privateState))

        let events = try SelectionClipboardReader.makeCopyShortcutEvents(eventSource: eventSource)

        XCTAssertEqual(SelectionClipboardReader.syntheticCopyEventUserData, 0x494E_4B4C_4554)
        XCTAssertEqual(
            events.keyDown.getIntegerValueField(.eventSourceUserData),
            SelectionClipboardReader.syntheticCopyEventUserData
        )
        XCTAssertEqual(
            events.keyUp.getIntegerValueField(.eventSourceUserData),
            SelectionClipboardReader.syntheticCopyEventUserData
        )
    }

    @MainActor
    func testCancellationDuringFinalSourceValidationReturnsEmptyAfterCleanup() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)
        let state = FinalValidationCancellationTestState()

        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in
                state.validationCount += 1
                if state.validationCount == 2 {
                    state.cancelOuterRead?()
                }
                return true
            },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in
                pasteboard.clearContents()
                pasteboard.setString("Owned selection", forType: .string)
                return .performed
            },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let readTask = Task { @MainActor in
            await reader.readSelectedText(
                sourceProcessIdentifier: 42,
                forceSelectionMode: .menuCopyOnly
            )
        }
        state.cancelOuterRead = { readTask.cancel() }

        let result = await readTask.value

        XCTAssertEqual(state.validationCount, 2)
        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testTimeoutAfterOwnedEmptyCopyRestoresOriginal() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1,
            pollTimeoutNanoseconds: 2,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in
                pasteboard.clearContents()
                return .performed
            },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .menuCopyOnly
        )

        XCTAssertEqual(result, .emptySelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testSourceInvalidationBeforeShortcutFallbackReturnsEmptyWithoutShortcut() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        var validationCount = 0
        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            sourceProcessValidator: { _ in
                validationCount += 1
                return validationCount == 1
            },
            isTrusted: { true },
            copyMenuActionPerformer: { _ in .noMenuItem },
            copyShortcutSender: { _ in didSendShortcut = true },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .menuCopyThenShortcut
        )

        XCTAssertEqual(result, .emptySelection)
        XCTAssertFalse(didSendShortcut)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testOverlappingReadsWaitForPriorCleanupBeforeTakingNextSnapshot() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)
        let firstReadPolling = expectation(description: "first read entered polling")
        var events: [String] = []
        var actionCount = 0
        var didStartFirstDelay = false
        var didValidateSecondSource = false

        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1_000_000_000,
            pollTimeoutNanoseconds: 60_000_000_000,
            sourceProcessValidator: { processIdentifier in
                events.append("validate \(processIdentifier)")
                if processIdentifier == 202, !didValidateSecondSource {
                    didValidateSecondSource = true
                    XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
                }
                return true
            },
            isTrusted: { true },
            copyMenuActionPerformer: { processIdentifier in
                actionCount += 1
                events.append("action \(processIdentifier)")
                pasteboard.clearContents()
                if actionCount == 2 {
                    pasteboard.setString("Second selection", forType: .string)
                }
                return .performed
            },
            delayProvider: { _ in
                guard !didStartFirstDelay else { return }
                didStartFirstDelay = true
                events.append("first delay started")
                firstReadPolling.fulfill()
                while actionCount < 2, !Task.isCancelled {
                    await Task.yield()
                }
                events.append("first delay ended")
            },
            shortcutReadWrapper: { operation in await operation() }
        )

        let firstReadTask = Task { @MainActor in
            await reader.readSelectedText(
                sourceProcessIdentifier: 101,
                forceSelectionMode: .menuCopyOnly
            )
        }
        await fulfillment(of: [firstReadPolling], timeout: 1)

        let secondResult = await reader.readSelectedText(
            sourceProcessIdentifier: 202,
            forceSelectionMode: .menuCopyOnly
        )
        let firstResult = await firstReadTask.value

        XCTAssertEqual(firstResult, .emptySelection)
        XCTAssertEqual(secondResult, .success("Second selection"))
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
        XCTAssertLessThan(
            try XCTUnwrap(events.firstIndex(of: "first delay ended")),
            try XCTUnwrap(events.firstIndex(of: "validate 202"))
        )
        XCTAssertEqual(actionCount, 2)
    }

    @MainActor
    func testThreeOverlappingReadsRecheckActiveReadAfterAwaitingPriorCleanup() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)
        let firstReadPolling = expectation(description: "first read entered polling")
        let secondCallerStarted = expectation(description: "second caller started")
        let thirdCallerStarted = expectation(description: "third caller started")
        let state = ThreeReadTestState()

        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            pollIntervalNanoseconds: 1_000_000_000,
            pollTimeoutNanoseconds: 60_000_000_000,
            sourceProcessValidator: { _ in true },
            isTrusted: { true },
            copyMenuActionPerformer: { processIdentifier in
                state.actionProcessIdentifiers.append(processIdentifier)
                pasteboard.clearContents()
                if processIdentifier == 303 {
                    state.didOverlapSyntheticActions = state.isSecondReadPolling
                    state.didRunThirdAction = true
                    pasteboard.setString("Third selection", forType: .string)
                }
                return .performed
            },
            delayProvider: { _ in
                if !state.didStartFirstDelay {
                    state.didStartFirstDelay = true
                    firstReadPolling.fulfill()
                    while !state.releaseFirstRead {
                        await Task.yield()
                    }
                    return
                }

                if !state.didStartSecondDelay {
                    state.didStartSecondDelay = true
                    state.isSecondReadPolling = true
                    while !Task.isCancelled, !state.didRunThirdAction {
                        await Task.yield()
                    }
                    state.isSecondReadPolling = false
                }
            },
            shortcutReadWrapper: { operation in await operation() }
        )

        let firstReadTask = Task { @MainActor in
            await reader.readSelectedText(
                sourceProcessIdentifier: 101,
                forceSelectionMode: .menuCopyOnly
            )
        }
        await fulfillment(of: [firstReadPolling], timeout: 1)

        let secondReadTask = Task { @MainActor in
            secondCallerStarted.fulfill()
            return await reader.readSelectedText(
                sourceProcessIdentifier: 202,
                forceSelectionMode: .menuCopyOnly
            )
        }
        await fulfillment(of: [secondCallerStarted], timeout: 1)

        let thirdReadTask = Task { @MainActor in
            thirdCallerStarted.fulfill()
            return await reader.readSelectedText(
                sourceProcessIdentifier: 303,
                forceSelectionMode: .menuCopyOnly
            )
        }
        await fulfillment(of: [thirdCallerStarted], timeout: 1)
        state.releaseFirstRead = true

        let firstResult = await firstReadTask.value
        let secondResult = await secondReadTask.value
        let thirdResult = await thirdReadTask.value

        XCTAssertEqual(firstResult, .emptySelection)
        XCTAssertEqual(secondResult, .emptySelection)
        XCTAssertEqual(thirdResult, .success("Third selection"))
        XCTAssertFalse(state.didOverlapSyntheticActions)
        XCTAssertEqual(state.actionProcessIdentifiers, [101, 303])
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }
}

@MainActor
private final class ThreeReadTestState {
    var releaseFirstRead = false
    var didStartFirstDelay = false
    var didStartSecondDelay = false
    var isSecondReadPolling = false
    var didRunThirdAction = false
    var didOverlapSyntheticActions = false
    var actionProcessIdentifiers: [pid_t] = []
}

@MainActor
private final class FinalValidationCancellationTestState {
    var validationCount = 0
    var cancelOuterRead: (() -> Void)?
}

@MainActor
private final class PendingHandoffTestState {
    var releaseFirstRead = false
    var firstReadObservedCancellation = false
    var actionProcessIdentifiers: [pid_t] = []
}

@MainActor
private final class PreTransactionHandoffTestState {
    var releaseWrapper = false
    var didSendShortcut = false
}
