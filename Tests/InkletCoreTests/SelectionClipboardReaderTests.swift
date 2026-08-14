import AppKit
import XCTest
@testable import InkletCore

final class SelectionClipboardReaderTests: XCTestCase {
    @MainActor
    func testMenuActionReadsChangedPasteboardAndRestoresOriginalItems() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let customType = NSPasteboard.PasteboardType("com.inklet.test.selection.binary")
        let customData = Data([0x11, 0x22, 0x33])
        let originalItem = NSPasteboardItem()
        XCTAssertTrue(originalItem.setString("Original clipboard", forType: .string))
        XCTAssertTrue(originalItem.setData(customData, forType: customType))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([originalItem]))

        var requestedProcessIdentifier: pid_t?
        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
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
            forceSelectionMode: .menuCopyThenShortcut,
            allowsSimulatedCopyFallback: true
        )

        XCTAssertEqual(result, .success("copied selection"))
        XCTAssertEqual(requestedProcessIdentifier, 42)
        XCTAssertFalse(didSendShortcut)

        let restoredItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restoredItems.count, 1)
        XCTAssertEqual(restoredItems[0].string(forType: .string), "Original clipboard")
        XCTAssertEqual(restoredItems[0].data(forType: customType), customData)
    }

    @MainActor
    func testNoCopyMenuItemFallsBackToShortcutCopy() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            activeProcessIdentifierProvider: { 42 },
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
            forceSelectionMode: .menuCopyThenShortcut,
            allowsSimulatedCopyFallback: true
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
    func testLegacyShortcutFirstModeUsesMenuBeforeSimulatedShortcut() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        var didSendShortcut = false
        var didRequestMenu = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
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
            forceSelectionMode: .shortcutThenMenuCopy,
            allowsSimulatedCopyFallback: true
        )

        XCTAssertEqual(result, .success("Menu selection"))
        XCTAssertFalse(didSendShortcut)
        XCTAssertTrue(didRequestMenu)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testShortcutCapableModeCannotSendShortcutWithoutExplicitPermission() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)
        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            activeProcessIdentifierProvider: { 42 },
            copyMenuActionPerformer: { _ in .noMenuItem },
            copyShortcutSender: { _ in didSendShortcut = true },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .menuCopyThenShortcut,
            allowsSimulatedCopyFallback: false
        )

        XCTAssertEqual(result, .unsupported)
        XCTAssertFalse(didSendShortcut)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testExplicitPermissionUsesMenuThenShortcutForOriginalForegroundProcess() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)
        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            activeProcessIdentifierProvider: { 42 },
            copyMenuActionPerformer: { _ in .noMenuItem },
            copyShortcutSender: { _ in
                didSendShortcut = true
                pasteboard.clearContents()
                pasteboard.setString("selection", forType: .string)
            },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .menuCopyOnly,
            allowsSimulatedCopyFallback: true
        )

        XCTAssertEqual(result, .success("selection"))
        XCTAssertTrue(didSendShortcut)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testAppSwitchPreventsOptionalShortcut() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)
        var didSendShortcut = false
        let reader = SelectionClipboardReader(
            pasteboard: pasteboard,
            activeProcessIdentifierProvider: { 99 },
            copyMenuActionPerformer: { _ in .noMenuItem },
            copyShortcutSender: { _ in didSendShortcut = true },
            delayProvider: { _ in },
            shortcutReadWrapper: { operation in await operation() }
        )

        let result = await reader.readSelectedText(
            sourceProcessIdentifier: 42,
            forceSelectionMode: .menuCopyOnly,
            allowsSimulatedCopyFallback: true
        )

        XCTAssertEqual(result, .unsupported)
        XCTAssertFalse(didSendShortcut)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    @MainActor
    func testGeneratedCopyEventsCarryInkletMarker() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let events = try SelectionClipboardReader.makeCopyShortcutEvents(eventSource: source)

        XCTAssertEqual(
            events.keyDown.getIntegerValueField(.eventSourceUserData),
            SelectionClipboardReader.generatedCopyEventUserData
        )
        XCTAssertEqual(
            events.keyUp.getIntegerValueField(.eventSourceUserData),
            SelectionClipboardReader.generatedCopyEventUserData
        )
    }
}
