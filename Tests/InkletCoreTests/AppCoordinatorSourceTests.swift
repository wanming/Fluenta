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

    func testAutomaticSelectionReadUsesGenericPipelineWithImmutableCapturedRequest() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/AppCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let clipboardSourceURL = packageRoot.appendingPathComponent(
            "Sources/InkletCore/SelectionClipboardReader.swift"
        )
        let clipboardSource = try String(contentsOf: clipboardSourceURL, encoding: .utf8)
        let candidateRange = try XCTUnwrap(source.range(of: "private func handleSelectionActionCandidate"))
        let copyTriggerRange = try XCTUnwrap(source.range(
            of: "\n    private func handleSelectionActionCopyTrigger",
            range: candidateRange.upperBound..<source.endIndex
        ))
        let candidateBlock = source[candidateRange.lowerBound..<copyTriggerRange.lowerBound]
        let scheduleReadRange = try XCTUnwrap(source.range(of: "case .scheduleRead"))
        let cancelReadRange = try XCTUnwrap(source.range(
            of: "\n            case .cancelRead",
            range: scheduleReadRange.upperBound..<source.endIndex
        ))
        let scheduleReadBlock = source[scheduleReadRange.lowerBound..<cancelReadRange.lowerBound]

        XCTAssertTrue(source.contains("private let selectionReadPipeline: SelectionReadPipeline"))
        XCTAssertTrue(source.contains("let selectionSourceValidator = SelectionSourceValidator()"))
        XCTAssertTrue(source.contains("SelectionClipboardReader("))
        XCTAssertTrue(source.contains("sourceProcessValidator: sourceValidator"))
        XCTAssertTrue(source.contains("SelectionReadPipeline("))
        XCTAssertTrue(source.contains("sourceValidator: sourceValidator"))
        XCTAssertTrue(source.contains("private struct PendingSelectionRead"))
        XCTAssertTrue(source.contains("let sourceProcessIdentifier: pid_t"))
        XCTAssertTrue(source.contains("let location: SelectionPoint"))
        XCTAssertTrue(candidateBlock.contains("let request = PendingSelectionRead("))
        XCTAssertTrue(candidateBlock.contains("sourceProcessIdentifier: sourceApp.processIdentifier"))
        XCTAssertTrue(candidateBlock.contains("location: point"))
        XCTAssertTrue(candidateBlock.contains("pendingSelectionRead: request"))
        XCTAssertTrue(scheduleReadBlock.contains("guard let pendingSelectionRead"))
        XCTAssertTrue(scheduleReadBlock.contains("completeScheduledSelectionRead(pendingSelectionRead)"))
        XCTAssertFalse(scheduleReadBlock.contains("let forceSelectionMode"))

        let automaticReadRange = try XCTUnwrap(source.range(of: "private func completeScheduledSelectionRead"))
        let noticeRange = try XCTUnwrap(source.range(
            of: "\n    private func showSelectionUnsupportedNotice",
            range: automaticReadRange.upperBound..<source.endIndex
        ))
        let automaticReadBlock = source[automaticReadRange.lowerBound..<noticeRange.lowerBound]
        XCTAssertTrue(automaticReadBlock.contains("let config ="))
        XCTAssertTrue(automaticReadBlock.contains("let forceSelectionMode = config.selectionActions.forceSelectionMode"))
        XCTAssertTrue(automaticReadBlock.contains("selectionReadPipeline.readSelectedText"))
        XCTAssertTrue(automaticReadBlock.contains("sourceProcessIdentifier: pendingSelectionRead.sourceProcessIdentifier"))
        XCTAssertTrue(automaticReadBlock.contains("mouseLocation: pendingSelectionRead.location"))
        XCTAssertTrue(automaticReadBlock.contains("forceSelectionMode: forceSelectionMode"))
        let removedBrowserReaderType = ["Selection", "Browser", "TextReader"].joined()
        let removedBrowserReaderProperty = ["selection", "Browser", "TextReader"].joined()
        let removedBrowserResult = ["browser", "Result"].joined()
        XCTAssertFalse(source.contains(removedBrowserReaderType))
        XCTAssertFalse(source.contains(removedBrowserReaderProperty))
        XCTAssertFalse(source.contains("pendingSelectionSourceBundleIdentifier"))
        XCTAssertFalse(source.contains("pendingSelectionSourceProcessIdentifier"))
        XCTAssertFalse(source.contains("pendingSelectionLocation"))
        XCTAssertFalse(source.contains("isFocusedSelectableTextElement"))
        XCTAssertFalse(source.contains("sourceProcessIdentifier: pid_t?"))
        XCTAssertFalse(source.contains(removedBrowserResult))
        XCTAssertFalse(clipboardSource.contains("sourceProcessIdentifier: pid_t?"))
        XCTAssertFalse(clipboardSource.contains("Compatibility for the current app caller"))

        let effectsRange = try XCTUnwrap(source.range(
            of: "\n    private func handleSelectionActionEffects",
            range: copyTriggerRange.upperBound..<source.endIndex
        ))
        let copyTriggerBlock = source[copyTriggerRange.lowerBound..<effectsRange.lowerBound]
        XCTAssertTrue(copyTriggerBlock.contains("NSPasteboard.general.string"))
    }

    func testSelectionMonitorSourcePreservesNativeRightClickAndMultiClickSelection() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/SelectionActionMonitor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let mouseUpStart = try XCTUnwrap(source.range(
            of: "NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]"
        ))
        let keyUpStart = try XCTUnwrap(source.range(
            of: "NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]",
            range: mouseUpStart.upperBound..<source.endIndex
        ))
        let mouseUpBlock = source[mouseUpStart.lowerBound..<keyUpStart.lowerBound]

        XCTAssertFalse(mouseUpBlock.contains(".rightMouseUp"))
        XCTAssertTrue(mouseUpBlock.contains("clickCount: event.clickCount"))
        XCTAssertTrue(mouseUpBlock.contains("dragPolicy.consumeMouseUpAction"))
    }

    func testSelectionActionsDoNotHardcodeIgnoredAppBundleIDs() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletCore/SelectionActionCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("com.apple.Maps"))
        XCTAssertFalse(source.contains("defaultIgnoredAutomaticSelectionAppBundleIDs"))
    }
}
