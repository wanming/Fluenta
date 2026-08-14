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
        XCTAssertTrue(automaticReadBlock.contains(
            "let configuredForceSelectionMode = config.selectionActions.forceSelectionMode"
        ))
        XCTAssertTrue(automaticReadBlock.contains("config.selectionActions.allowsSimulatedCopyFallback"))
        XCTAssertTrue(automaticReadBlock.contains(".menuCopyThenShortcut"))
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
        XCTAssertFalse(copyTriggerBlock.contains("selectionReadPipeline"))
    }

    func testDoubleCopyCapturesImmutableRequestAndUsesOnlyPassiveReader() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/AppCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let callbackStart = try XCTUnwrap(source.range(
            of: "self.selectionActionMonitor.onCopyTrigger ="
        ))
        let dismissCallbackStart = try XCTUnwrap(source.range(
            of: "self.selectionActionMonitor.onDismiss =",
            range: callbackStart.upperBound..<source.endIndex
        ))
        let callbackBlock = source[callbackStart.lowerBound..<dismissCallbackStart.lowerBound]
        let copyTriggerStart = try XCTUnwrap(source.range(
            of: "private func handleSelectionActionCopyTrigger"
        ))
        let effectsStart = try XCTUnwrap(source.range(
            of: "\n    private func handleSelectionActionEffects",
            range: copyTriggerStart.upperBound..<source.endIndex
        ))
        let copyTriggerBlock = source[copyTriggerStart.lowerBound..<effectsStart.lowerBound]
        let finishHandoff = try XCTUnwrap(copyTriggerBlock.range(
            of: "await selectionClipboardReader.finishUserCopyHandoff("
        ))
        let unobservedSyntheticActionGuard = try XCTUnwrap(copyTriggerBlock.range(
            of: "case .unobservedSyntheticAction:"
        ))
        let passiveRead = try XCTUnwrap(copyTriggerBlock.range(
            of: "await selectionUserCopyReader.readCopiedText("
        ))
        let finalSourceValidation = try XCTUnwrap(copyTriggerBlock.range(
            of: "selectionSourceValidator.isCurrent"
        ))
        let showPanel = try XCTUnwrap(copyTriggerBlock.range(
            of: "selectionActionWindowController.showMenu(at: pendingUserCopyRead.location)"
        ))
        let afterPassiveReadBlock = copyTriggerBlock[passiveRead.upperBound..<showPanel.lowerBound]
        let userCopyReaderInitializerStart = try XCTUnwrap(source.range(
            of: "let selectionUserCopyReader = SelectionUserCopyReader("
        ))
        let storedPropertiesStart = try XCTUnwrap(source.range(
            of: "\n        self.migrationOutcome = migrationOutcome",
            range: userCopyReaderInitializerStart.upperBound..<source.endIndex
        ))
        let userCopyReaderInitializer = source[
            userCopyReaderInitializerStart.lowerBound..<storedPropertiesStart.lowerBound
        ]

        XCTAssertTrue(source.contains("private let selectionSourceValidator: SelectionSourceValidator"))
        XCTAssertTrue(source.contains("private let selectionClipboardReader: SelectionClipboardReader"))
        XCTAssertTrue(source.contains("private let selectionUserCopyReader: SelectionUserCopyReader"))
        XCTAssertTrue(userCopyReaderInitializer.contains("sourceProcessValidator: sourceValidator"))
        XCTAssertTrue(source.contains("private struct PendingUserCopyRead"))
        XCTAssertTrue(source.contains("let clipboardHandoff: SelectionClipboardUserCopyHandoff"))

        XCTAssertTrue(callbackBlock.contains("trigger in"))
        XCTAssertTrue(callbackBlock.contains("trigger.sourceProcessIdentifier > 0"))
        XCTAssertTrue(callbackBlock.contains("trigger.sourceProcessIdentifier != NSRunningApplication.current.processIdentifier"))
        XCTAssertTrue(callbackBlock.contains("selectionSourceValidator.isCurrent(trigger.sourceProcessIdentifier)"))
        XCTAssertTrue(callbackBlock.contains("let clipboardHandoff = selectionClipboardReader.beginUserCopyHandoff()"))
        XCTAssertTrue(callbackBlock.contains("let pendingUserCopyRead = PendingUserCopyRead("))
        XCTAssertTrue(callbackBlock.contains("sourceProcessIdentifier: trigger.sourceProcessIdentifier"))
        XCTAssertTrue(callbackBlock.contains("location: trigger.point"))
        XCTAssertTrue(callbackBlock.contains("clipboardHandoff: clipboardHandoff"))
        XCTAssertTrue(callbackBlock.contains("handleSelectionActionCopyTrigger(pendingUserCopyRead)"))
        XCTAssertFalse(callbackBlock.contains("Task"))
        XCTAssertFalse(callbackBlock.contains("NSWorkspace.shared.frontmostApplication"))
        XCTAssertFalse(callbackBlock.contains("NSEvent.mouseLocation"))

        XCTAssertLessThan(finishHandoff.lowerBound, passiveRead.lowerBound)
        XCTAssertLessThan(finishHandoff.lowerBound, unobservedSyntheticActionGuard.lowerBound)
        XCTAssertLessThan(unobservedSyntheticActionGuard.lowerBound, passiveRead.lowerBound)
        XCTAssertTrue(copyTriggerBlock.contains("let handoffOutcome = await selectionClipboardReader.finishUserCopyHandoff("))
        XCTAssertTrue(copyTriggerBlock.contains("SelectionActionDiagnostics.log(\"copy trigger ignored unobserved synthetic action\")"))
        XCTAssertTrue(copyTriggerBlock.contains("case .noActiveRead, .restorationRelinquished, .completedWithoutPasteboardMutation:"))
        XCTAssertTrue(copyTriggerBlock.contains("sourceProcessIdentifier: pendingUserCopyRead.sourceProcessIdentifier"))
        XCTAssertTrue(copyTriggerBlock.contains("after: pendingUserCopyRead.clipboardHandoff.boundaryChangeCount"))
        XCTAssertTrue(afterPassiveReadBlock.contains("guard !Task.isCancelled,"))
        XCTAssertTrue(afterPassiveReadBlock.contains("!isMigrationMaintenanceActive"))
        XCTAssertTrue(afterPassiveReadBlock.contains("selectionReadTaskID == taskID"))
        XCTAssertTrue(afterPassiveReadBlock.contains("selectionSourceValidator.isCurrent"))
        XCTAssertTrue(afterPassiveReadBlock.contains("guard case .success(let text) = result, !text.isEmpty"))
        XCTAssertLessThan(finalSourceValidation.lowerBound, showPanel.lowerBound)
        XCTAssertTrue(copyTriggerBlock.contains("selectionReadTaskID == taskID"))
        XCTAssertTrue(copyTriggerBlock.contains("guard !Task.isCancelled,"))
        XCTAssertTrue(copyTriggerBlock.contains("!isMigrationMaintenanceActive"))

        let forbiddenDoubleCopyTokens = [
            "selectionReadPipeline",
            "selectionClipboardReader.readSelectedText",
            "readSelectedTextForAutomaticSelection",
            "NSPasteboard.general.string",
            "CGEvent(",
            "copyMenuAction",
            "clearContents()",
            "writeObjects("
        ]
        for token in forbiddenDoubleCopyTokens {
            XCTAssertFalse(copyTriggerBlock.contains(token), "Double-copy handler must not contain \(token)")
        }
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

        XCTAssertFalse(mouseUpBlock.contains(".rightMouseDown"))
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
