import XCTest

final class AppCoordinatorSourceTests: XCTestCase {
    func testUpdateCheckerConstructionUsesProductionOnlyAutomaticChecks() throws {
        let source = try appCoordinatorSource()
        let factoryStart = try XCTUnwrap(source.range(
            of: "private func makeUpdateCheckCoordinator() -> UpdateCheckCoordinator"
        ))
        let startMethod = try XCTUnwrap(source.range(
            of: "\n    func start()",
            range: factoryStart.upperBound..<source.endIndex
        ))
        let factoryBlock = source[factoryStart.lowerBound..<startMethod.lowerBound]

        XCTAssertEqual(
            source.components(separatedBy: "private lazy var updateCheckCoordinator = makeUpdateCheckCoordinator()").count - 1,
            1
        )
        XCTAssertEqual(
            source.components(separatedBy: "private func makeUpdateCheckCoordinator() -> UpdateCheckCoordinator").count - 1,
            1
        )
        XCTAssertTrue(factoryBlock.contains("let checker = GitHubReleaseUpdateChecker()"))
        XCTAssertTrue(factoryBlock.contains(
            "Bundle.main.object(forInfoDictionaryKey: \"CFBundleVersion\") as? String"
        ))
        XCTAssertTrue(factoryBlock.contains(
            "automaticChecksEnabled: storagePaths.bundleIdentifier == InkletStoragePaths.productionBundleIdentifier"
        ))
        XCTAssertTrue(factoryBlock.contains("currentVersion: BuildInfo.displayVersion"))
        XCTAssertTrue(factoryBlock.contains("scheduler: FoundationUpdateCheckOneShotScheduler()"))
        XCTAssertTrue(factoryBlock.contains("presenter: UpdateCheckAlertPresenter()"))
        XCTAssertTrue(factoryBlock.contains("canPresentAutomatically: { [weak self] in"))
        XCTAssertTrue(factoryBlock.contains("self?.canPresentAutomaticUpdate ?? false"))
        XCTAssertTrue(factoryBlock.contains("checker.check(currentBuildNumber: currentBuildNumber)"))
        XCTAssertFalse(factoryBlock.contains("userDefaults:"))
        XCTAssertEqual(
            factoryBlock.components(separatedBy: "coordinator.onCheckingStateChange").count - 1,
            1
        )
        XCTAssertTrue(factoryBlock.contains("coordinator.onCheckingStateChange = { [weak self] _ in"))
        XCTAssertTrue(factoryBlock.contains("self?.configureMainMenu()"))
        XCTAssertTrue(factoryBlock.contains("self?.configureStatusItemMenu()"))
    }

    func testUpdateCheckerFollowsAppLifecycle() throws {
        let source = try appCoordinatorSource()
        let startRange = try XCTUnwrap(source.range(of: "func start()"))
        let stopRange = try XCTUnwrap(source.range(
            of: "\n    func stop()",
            range: startRange.upperBound..<source.endIndex
        ))
        let configureMainMenuRange = try XCTUnwrap(source.range(
            of: "\n    private func configureMainMenu",
            range: stopRange.upperBound..<source.endIndex
        ))
        let startBlock = source[startRange.lowerBound..<stopRange.lowerBound]
        let stopBlock = source[stopRange.lowerBound..<configureMainMenuRange.lowerBound]
        let migrationNotice = try XCTUnwrap(startBlock.range(of: "settingsController.showMigrationNotice()"))
        let updateStart = try XCTUnwrap(startBlock.range(of: "updateCheckCoordinator.start()"))

        XCTAssertLessThan(migrationNotice.lowerBound, updateStart.lowerBound)
        XCTAssertTrue(
            startBlock[updateStart.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) == "}"
        )
        XCTAssertTrue(stopBlock.contains("updateCheckCoordinator.stop()"))
    }

    func testUpdateMenuItemSharesActionAndAppearsInBothMenus() throws {
        let source = try appCoordinatorSource()
        let helperStart = try XCTUnwrap(source.range(
            of: "private func makeCheckForUpdatesMenuItem() -> NSMenuItem"
        ))
        let statusMenuStart = try XCTUnwrap(source.range(
            of: "\n    private func configureStatusItemMenu()",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helperBlock = source[helperStart.lowerBound..<statusMenuStart.lowerBound]

        XCTAssertTrue(helperBlock.contains("let isChecking = updateCheckCoordinator.isChecking"))
        XCTAssertEqual(
            helperBlock.components(separatedBy: "updateCheckCoordinator.isChecking").count - 1,
            1
        )
        XCTAssertTrue(helperBlock.contains("\"app.menu.checkingForUpdates\""))
        XCTAssertTrue(helperBlock.contains("\"app.menu.checkForUpdates\""))
        XCTAssertTrue(helperBlock.contains("action: #selector(checkForUpdates)"))
        XCTAssertTrue(helperBlock.contains("item.target = self"))
        XCTAssertTrue(helperBlock.contains("item.isEnabled = !isChecking"))
        XCTAssertFalse(helperBlock.contains("image"))

        let mainMenuStart = try XCTUnwrap(source.range(of: "private func configureMainMenu()"))
        let settingsShortcutStart = try XCTUnwrap(source.range(
            of: "\n    private func installSettingsShortcutMonitor",
            range: mainMenuStart.upperBound..<source.endIndex
        ))
        let mainMenuBlock = source[mainMenuStart.lowerBound..<settingsShortcutStart.lowerBound]
        let aboutAdd = try XCTUnwrap(mainMenuBlock.range(of: "appMenu.addItem(aboutItem)"))
        let mainUpdateAdd = try XCTUnwrap(mainMenuBlock.range(
            of: "appMenu.addItem(makeCheckForUpdatesMenuItem())"
        ))
        let mainSeparator = try XCTUnwrap(mainMenuBlock.range(
            of: "appMenu.addItem(NSMenuItem.separator())",
            range: mainUpdateAdd.upperBound..<mainMenuBlock.endIndex
        ))
        let quitAdd = try XCTUnwrap(mainMenuBlock.range(
            of: "appMenu.addItem(quitItem)",
            range: mainSeparator.upperBound..<mainMenuBlock.endIndex
        ))
        XCTAssertLessThan(aboutAdd.lowerBound, mainUpdateAdd.lowerBound)
        XCTAssertLessThan(mainUpdateAdd.lowerBound, mainSeparator.lowerBound)
        XCTAssertLessThan(mainSeparator.lowerBound, quitAdd.lowerBound)

        let actionStart = try XCTUnwrap(source.range(
            of: "\n    @objc func openPopover()",
            range: statusMenuStart.upperBound..<source.endIndex
        ))
        let statusMenuBlock = source[statusMenuStart.lowerBound..<actionStart.lowerBound]
        let statusOpen = try XCTUnwrap(statusMenuBlock.range(
            of: "title: L10n.text(\"app.menu.openPopover\")"
        ))
        let statusFirstSeparator = try XCTUnwrap(statusMenuBlock.range(
            of: "menu.addItem(NSMenuItem.separator())",
            range: statusOpen.upperBound..<statusMenuBlock.endIndex
        ))
        let settingsAdd = try XCTUnwrap(statusMenuBlock.range(of: "menu.addItem(settingsItem)"))
        let statusUpdateAdd = try XCTUnwrap(statusMenuBlock.range(
            of: "menu.addItem(makeCheckForUpdatesMenuItem())"
        ))
        let statusSeparator = try XCTUnwrap(statusMenuBlock.range(
            of: "menu.addItem(NSMenuItem.separator())",
            range: statusUpdateAdd.upperBound..<statusMenuBlock.endIndex
        ))
        let statusAbout = try XCTUnwrap(statusMenuBlock.range(
            of: "title: L10n.text(\"app.menu.about\")",
            range: statusSeparator.upperBound..<statusMenuBlock.endIndex
        ))
        let statusQuit = try XCTUnwrap(statusMenuBlock.range(
            of: "title: L10n.text(\"app.menu.quit\")",
            range: statusAbout.upperBound..<statusMenuBlock.endIndex
        ))
        XCTAssertLessThan(statusOpen.lowerBound, statusFirstSeparator.lowerBound)
        XCTAssertLessThan(statusFirstSeparator.lowerBound, settingsAdd.lowerBound)
        XCTAssertLessThan(settingsAdd.lowerBound, statusUpdateAdd.lowerBound)
        XCTAssertLessThan(statusUpdateAdd.lowerBound, statusSeparator.lowerBound)
        XCTAssertLessThan(statusSeparator.lowerBound, statusAbout.lowerBound)
        XCTAssertLessThan(statusAbout.lowerBound, statusQuit.lowerBound)

        let languageObserverStart = try XCTUnwrap(source.range(of: "languageObserver ="))
        let registerHotkeyStart = try XCTUnwrap(source.range(
            of: "\n        registerConfiguredHotkey()",
            range: languageObserverStart.upperBound..<source.endIndex
        ))
        let languageObserverBlock = source[languageObserverStart.lowerBound..<registerHotkeyStart.lowerBound]
        XCTAssertTrue(languageObserverBlock.contains("self?.configureMainMenu()"))
        XCTAssertTrue(languageObserverBlock.contains("self?.configureStatusItemMenu()"))
        XCTAssertFalse(languageObserverBlock.contains("makeUpdateCheckCoordinator"))
    }

    func testUpdateActionAndAutomaticPresentationUseCentralizedEligibility() throws {
        let source = try appCoordinatorSource()
        let automaticGateStart = try XCTUnwrap(source.range(
            of: "private var canPresentAutomaticUpdate: Bool"
        ))
        let refreshStart = try XCTUnwrap(source.range(
            of: "\n    private func refreshMigrationImportEligibility()",
            range: automaticGateStart.upperBound..<source.endIndex
        ))
        let automaticGateBlock = source[automaticGateStart.lowerBound..<refreshStart.lowerBound]
        XCTAssertTrue(automaticGateBlock.contains("!isMigrationMaintenanceActive"))
        XCTAssertTrue(automaticGateBlock.contains("!isRecordingHotkey"))
        XCTAssertTrue(automaticGateBlock.contains("migrationWorkflowsAreIdle"))

        let requestMigrationStart = try XCTUnwrap(source.range(
            of: "\n    private func requestAssistedMigrationImport",
            range: refreshStart.upperBound..<source.endIndex
        ))
        let refreshBlock = source[refreshStart.lowerBound..<requestMigrationStart.lowerBound]
        XCTAssertTrue(refreshBlock.contains("migrationPresentationModel.setWorkflowsIdle("))
        XCTAssertTrue(refreshBlock.contains(
            "updateCheckCoordinator.presentPendingAutomaticUpdateIfPossible()"
        ))

        let hotkeyStart = try XCTUnwrap(source.range(of: "private func setHotkeyRecording"))
        let permissionStart = try XCTUnwrap(source.range(
            of: "\n    private func showPermissionSettingsIfNeeded",
            range: hotkeyStart.upperBound..<source.endIndex
        ))
        let hotkeyBlock = source[hotkeyStart.lowerBound..<permissionStart.lowerBound]
        let transitionGuard = try XCTUnwrap(hotkeyBlock.range(
            of: "guard isRecordingHotkey != isRecording"
        ))
        let stateChange = try XCTUnwrap(hotkeyBlock.range(of: "isRecordingHotkey = isRecording"))
        let unregister = try XCTUnwrap(hotkeyBlock.range(of: "hotkeyManager.unregister()"))
        let register = try XCTUnwrap(hotkeyBlock.range(of: "registerConfiguredHotkey()"))
        let refresh = try XCTUnwrap(hotkeyBlock.range(of: "refreshMigrationImportEligibility()"))
        XCTAssertLessThan(transitionGuard.lowerBound, stateChange.lowerBound)
        XCTAssertLessThan(stateChange.lowerBound, refresh.lowerBound)
        XCTAssertLessThan(unregister.lowerBound, refresh.lowerBound)
        XCTAssertLessThan(register.lowerBound, refresh.lowerBound)
        XCTAssertEqual(
            hotkeyBlock.components(separatedBy: "refreshMigrationImportEligibility()").count - 1,
            1
        )

        let checkActionStart = try XCTUnwrap(source.range(of: "@objc func checkForUpdates()"))
        let openPopoverStart = try XCTUnwrap(source.range(
            of: "\n    @objc func openPopover()",
            range: checkActionStart.upperBound..<source.endIndex
        ))
        let checkActionBlock = source[checkActionStart.lowerBound..<openPopoverStart.lowerBound]
        XCTAssertTrue(checkActionBlock.contains("updateCheckCoordinator.checkManually()"))
    }

    func testUpdateWiringDoesNotAddUpdaterFrameworkOrInstallBehavior() throws {
        let source = try appCoordinatorSource()
        let forbiddenTokens = [
            "import Sparkle",
            "SPUStandardUpdaterController",
            "downloadUpdate",
            "installUpdate",
        ]

        for token in forbiddenTokens {
            XCTAssertFalse(source.contains(token), "AppCoordinator must not contain \(token)")
        }
    }

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

    private func appCoordinatorSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/AppCoordinator.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
