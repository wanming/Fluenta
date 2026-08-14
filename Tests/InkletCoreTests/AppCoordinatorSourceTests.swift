import XCTest

final class AppCoordinatorSourceTests: XCTestCase {
    func testSelectionTranslationsUseCache() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/AppCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let translateRange = try XCTUnwrap(source.range(of: "private func translateCurrentSelection"))
        let nextRange = try XCTUnwrap(source.range(
            of: "\n    private func pronounceCurrentSelection",
            range: translateRange.upperBound..<source.endIndex
        ))
        let translateBlock = source[translateRange.lowerBound..<nextRange.lowerBound]

        XCTAssertTrue(source.contains("private let selectionTranslationCache"))
        XCTAssertTrue(translateBlock.contains("CachedSelectionTranslationService"))
        XCTAssertTrue(translateBlock.contains("cache: selectionTranslationCache"))
        XCTAssertTrue(translateBlock.contains("targetLanguageName: targetLanguageName"))
        XCTAssertTrue(translateBlock.contains("providerID: providerID"))
    }

    func testAutomaticSelectionReadUsesEasyDictStyleFallbackPipeline() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/AppCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let scheduleReadRange = try XCTUnwrap(source.range(of: "case .scheduleRead"))
        let cancelReadRange = try XCTUnwrap(source.range(
            of: "\n            case .cancelRead",
            range: scheduleReadRange.upperBound..<source.endIndex
        ))
        let scheduleReadBlock = source[scheduleReadRange.lowerBound..<cancelReadRange.lowerBound]

        XCTAssertTrue(scheduleReadBlock.contains("completeScheduledSelectionRead"))
        XCTAssertTrue(source.contains("private func readSelectedTextForAutomaticSelection"))

        let automaticReadRange = try XCTUnwrap(source.range(of: "private func readSelectedTextForAutomaticSelection"))
        let noticeRange = try XCTUnwrap(source.range(
            of: "\n    private func showSelectionUnsupportedNotice",
            range: automaticReadRange.upperBound..<source.endIndex
        ))
        let automaticReadBlock = source[automaticReadRange.lowerBound..<noticeRange.lowerBound]
        XCTAssertTrue(automaticReadBlock.contains("selectedTextReader.readSelectedText"))
        XCTAssertTrue(automaticReadBlock.contains("selectedTextReader.isFocusedSelectableTextElement"))
        XCTAssertTrue(automaticReadBlock.contains("selectionBrowserTextReader.readSelectedText"))
        XCTAssertTrue(automaticReadBlock.contains("selectionClipboardReader.readSelectedText"))
        XCTAssertTrue(automaticReadBlock.contains("forceSelectionMode: config.selectionActions.forceSelectionMode"))
        XCTAssertTrue(automaticReadBlock.contains(
            "allowsSimulatedCopyFallback: config.selectionActions.allowsSimulatedCopyFallback"
        ))

        let copyTriggerRange = try XCTUnwrap(source.range(of: "private func handleSelectionActionCopyTrigger"))
        let effectsRange = try XCTUnwrap(source.range(
            of: "\n    private func handleSelectionActionEffects",
            range: copyTriggerRange.upperBound..<source.endIndex
        ))
        let copyTriggerBlock = source[copyTriggerRange.lowerBound..<effectsRange.lowerBound]
        XCTAssertTrue(copyTriggerBlock.contains("pasteboard.string"))
    }

    func testManualDoubleCopyValidatesClipboardChangeForSameSourceApp() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/AppCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let triggerRange = try XCTUnwrap(source.range(of: "private func handleSelectionActionCopyTrigger"))
        let effectsRange = try XCTUnwrap(source.range(
            of: "\n    private func handleSelectionActionEffects",
            range: triggerRange.upperBound..<source.endIndex
        ))
        let triggerBlock = source[triggerRange.lowerBound..<effectsRange.lowerBound]

        XCTAssertTrue(triggerBlock.contains("initialPasteboardChangeCount"))
        XCTAssertTrue(triggerBlock.contains("sourceProcessIdentifier"))
        XCTAssertTrue(triggerBlock.contains("NSWorkspace.shared.frontmostApplication?.processIdentifier"))
        XCTAssertTrue(triggerBlock.contains("SelectionCopyTriggerPolicy.validatedClipboardText"))
        XCTAssertTrue(triggerBlock.contains("currentChangeCount: pasteboard.changeCount"))
        XCTAssertTrue(triggerBlock.contains("initialChangeCount: initialPasteboardChangeCount"))
        XCTAssertTrue(triggerBlock.contains("selectionActionWindowController.showMenu"))
    }

    func testSelectionActionsDoNotHardcodeIgnoredAppBundleIDs() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletCore/SelectionActionCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("com.apple.Maps"))
        XCTAssertFalse(source.contains("defaultIgnoredAutomaticSelectionAppBundleIDs"))
    }
}
