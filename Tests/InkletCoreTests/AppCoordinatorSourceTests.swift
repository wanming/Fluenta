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
        XCTAssertTrue(source.contains("private lazy var updateCheckAlertPresenter"))
        XCTAssertTrue(factoryBlock.contains("presenter: updateCheckAlertPresenter"))
        XCTAssertFalse(factoryBlock.contains("canPresentAutomatically:"))
        XCTAssertTrue(factoryBlock.contains("checker.check(currentBuildNumber: currentBuildNumber)"))
        XCTAssertFalse(factoryBlock.contains("userDefaults:"))
        XCTAssertEqual(
            factoryBlock.components(separatedBy: "coordinator.onCheckingStateChange").count - 1,
            1
        )
        XCTAssertTrue(factoryBlock.contains("coordinator.onCheckingStateChange = { [weak self] _ in"))
        XCTAssertTrue(factoryBlock.contains("self?.refreshUpdateCheckMenuItems()"))
        XCTAssertTrue(factoryBlock.contains("coordinator.onPendingAutomaticUpdate = { [weak self] in"))
        XCTAssertTrue(factoryBlock.contains("self?.automaticUpdatePresentationGate.schedule()"))
        XCTAssertFalse(factoryBlock.contains("self?.configureMainMenu()"))
        XCTAssertFalse(factoryBlock.contains("self?.configureStatusItemMenu()"))

        let presenterStart = try XCTUnwrap(source.range(of: "private lazy var updateCheckAlertPresenter"))
        let coordinatorStart = try XCTUnwrap(source.range(
            of: "private lazy var updateCheckCoordinator",
            range: presenterStart.upperBound..<source.endIndex
        ))
        let presenterBlock = source[presenterStart.lowerBound..<coordinatorStart.lowerBound]
        XCTAssertTrue(presenterBlock.contains("presenter.onPresentationStateChange = { [weak self] isPresenting in"))
        let menuRefresh = try XCTUnwrap(presenterBlock.range(of: "self?.refreshUpdateCheckMenuItems()"))
        let presentationEndGuard = try XCTUnwrap(presenterBlock.range(of: "guard !isPresenting else { return }"))
        XCTAssertLessThan(menuRefresh.lowerBound, presentationEndGuard.lowerBound)
        XCTAssertTrue(presenterBlock.contains("guard !isPresenting else { return }"))
        XCTAssertTrue(presenterBlock.contains("Task { @MainActor [weak self] in"))
        XCTAssertTrue(presenterBlock.contains("self?.refreshMigrationImportEligibility()"))
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
        let stoppingAssignment = try XCTUnwrap(stopBlock.range(of: "isStopping = true"))
        let updateStop = try XCTUnwrap(stopBlock.range(of: "updateCheckCoordinator.stop()"))
        let gateCancel = try XCTUnwrap(stopBlock.range(of: "automaticUpdatePresentationGate.cancel()"))
        let dictationCancellation = try XCTUnwrap(stopBlock.range(
            of: "await windowController.cancelDictationAndWait()"
        ))
        let observerRemoval = try XCTUnwrap(stopBlock.range(of: "if let configObserver"))

        XCTAssertLessThan(migrationNotice.lowerBound, updateStart.lowerBound)
        XCTAssertTrue(
            startBlock[updateStart.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) == "}"
        )
        XCTAssertLessThan(stoppingAssignment.lowerBound, updateStop.lowerBound)
        XCTAssertLessThan(gateCancel.lowerBound, updateStop.lowerBound)
        XCTAssertLessThan(gateCancel.lowerBound, dictationCancellation.lowerBound)
        XCTAssertLessThan(updateStop.lowerBound, dictationCancellation.lowerBound)
        XCTAssertLessThan(dictationCancellation.lowerBound, observerRemoval.lowerBound)
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

        XCTAssertTrue(helperBlock.contains("action: #selector(checkForUpdates)"))
        XCTAssertTrue(helperBlock.contains("item.target = self"))
        XCTAssertFalse(helperBlock.contains("image"))
        XCTAssertTrue(source.contains("private var mainUpdateCheckMenuItem: NSMenuItem?"))
        XCTAssertTrue(source.contains("private var statusUpdateCheckMenuItem: NSMenuItem?"))

        let refreshItemsStart = try XCTUnwrap(source.range(
            of: "private func refreshUpdateCheckMenuItems()"
        ))
        let statusMenuStartFromRefresh = try XCTUnwrap(source.range(
            of: "\n    private func configureStatusItemMenu()",
            range: refreshItemsStart.upperBound..<source.endIndex
        ))
        let refreshItemsBlock = source[
            refreshItemsStart.lowerBound..<statusMenuStartFromRefresh.lowerBound
        ]
        XCTAssertTrue(refreshItemsBlock.contains("let isChecking = updateCheckCoordinator.isChecking"))
        XCTAssertTrue(refreshItemsBlock.contains("\"app.menu.checkingForUpdates\""))
        XCTAssertTrue(refreshItemsBlock.contains("\"app.menu.checkForUpdates\""))
        XCTAssertTrue(refreshItemsBlock.contains("item.title = title"))
        XCTAssertTrue(refreshItemsBlock.contains("item.isEnabled = isUpdateCheckAvailable"))
        XCTAssertTrue(refreshItemsBlock.contains("[mainUpdateCheckMenuItem, statusUpdateCheckMenuItem]"))
        XCTAssertTrue(helperBlock.contains("private var isUpdateCheckAvailable: Bool"))
        XCTAssertTrue(helperBlock.contains("!updateCheckCoordinator.isChecking"))
        XCTAssertTrue(helperBlock.contains("!updateCheckAlertPresenter.isPresentingAlert"))

        let mainMenuStart = try XCTUnwrap(source.range(of: "private func configureMainMenu()"))
        let settingsShortcutStart = try XCTUnwrap(source.range(
            of: "\n    private func installSettingsShortcutMonitor",
            range: mainMenuStart.upperBound..<source.endIndex
        ))
        let mainMenuBlock = source[mainMenuStart.lowerBound..<settingsShortcutStart.lowerBound]
        XCTAssertTrue(mainMenuBlock.contains("UpdateCheckMenuConfiguration.apply(to: appMenu)"))
        XCTAssertTrue(mainMenuBlock.contains("let editMenu = NSMenu(title: \"Edit\")"))
        XCTAssertFalse(mainMenuBlock.contains("UpdateCheckMenuConfiguration.apply(to: editMenu)"))
        XCTAssertFalse(mainMenuBlock.contains("editMenu.autoenablesItems"))
        let aboutAdd = try XCTUnwrap(mainMenuBlock.range(of: "appMenu.addItem(aboutItem)"))
        let mainUpdateReference = try XCTUnwrap(mainMenuBlock.range(
            of: "mainUpdateCheckMenuItem = updateItem"
        ))
        let mainUpdateAdd = try XCTUnwrap(mainMenuBlock.range(of: "appMenu.addItem(updateItem)"))
        let mainSeparator = try XCTUnwrap(mainMenuBlock.range(
            of: "appMenu.addItem(NSMenuItem.separator())",
            range: mainUpdateAdd.upperBound..<mainMenuBlock.endIndex
        ))
        let quitAdd = try XCTUnwrap(mainMenuBlock.range(
            of: "appMenu.addItem(quitItem)",
            range: mainSeparator.upperBound..<mainMenuBlock.endIndex
        ))
        XCTAssertLessThan(aboutAdd.lowerBound, mainUpdateReference.lowerBound)
        XCTAssertLessThan(mainUpdateReference.lowerBound, mainUpdateAdd.lowerBound)
        XCTAssertLessThan(mainUpdateAdd.lowerBound, mainSeparator.lowerBound)
        XCTAssertLessThan(mainSeparator.lowerBound, quitAdd.lowerBound)

        let actionStart = try XCTUnwrap(source.range(
            of: "\n    @objc func openPopover()",
            range: statusMenuStart.upperBound..<source.endIndex
        ))
        let statusMenuBlock = source[statusMenuStart.lowerBound..<actionStart.lowerBound]
        XCTAssertTrue(statusMenuBlock.contains("UpdateCheckMenuConfiguration.apply(to: menu)"))
        let statusOpen = try XCTUnwrap(statusMenuBlock.range(
            of: "title: L10n.text(\"app.menu.openPopover\")"
        ))
        let statusFirstSeparator = try XCTUnwrap(statusMenuBlock.range(
            of: "menu.addItem(NSMenuItem.separator())",
            range: statusOpen.upperBound..<statusMenuBlock.endIndex
        ))
        let settingsAdd = try XCTUnwrap(statusMenuBlock.range(of: "menu.addItem(settingsItem)"))
        let statusUpdateReference = try XCTUnwrap(statusMenuBlock.range(
            of: "statusUpdateCheckMenuItem = updateItem"
        ))
        let statusUpdateAdd = try XCTUnwrap(statusMenuBlock.range(of: "menu.addItem(updateItem)"))
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
        XCTAssertLessThan(settingsAdd.lowerBound, statusUpdateReference.lowerBound)
        XCTAssertLessThan(statusUpdateReference.lowerBound, statusUpdateAdd.lowerBound)
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

    func testUpdateMenusTrackPresentationAndFlushOnClose() throws {
        let source = try appCoordinatorSource()

        XCTAssertTrue(source.contains("final class AppCoordinator: NSObject, NSMenuDelegate"))
        XCTAssertTrue(source.contains("private var trackedMenus: Set<ObjectIdentifier> = []"))

        let mainMenuStart = try XCTUnwrap(source.range(of: "private func configureMainMenu()"))
        let settingsShortcutStart = try XCTUnwrap(source.range(
            of: "\n    private func installSettingsShortcutMonitor",
            range: mainMenuStart.upperBound..<source.endIndex
        ))
        let mainMenuBlock = source[mainMenuStart.lowerBound..<settingsShortcutStart.lowerBound]
        XCTAssertTrue(mainMenuBlock.contains("appMenu.delegate = self"))
        XCTAssertTrue(mainMenuBlock.contains("editMenu.delegate = self"))

        let statusMenuStart = try XCTUnwrap(source.range(of: "private func configureStatusItemMenu()"))
        let checkActionStart = try XCTUnwrap(source.range(
            of: "\n    @objc func checkForUpdates()",
            range: statusMenuStart.upperBound..<source.endIndex
        ))
        let statusMenuBlock = source[statusMenuStart.lowerBound..<checkActionStart.lowerBound]
        XCTAssertTrue(statusMenuBlock.contains("menu.delegate = self"))

        let willOpenStart = try XCTUnwrap(source.range(of: "func menuWillOpen(_ menu: NSMenu)"))
        let didCloseStart = try XCTUnwrap(source.range(
            of: "\n    func menuDidClose(_ menu: NSMenu)",
            range: willOpenStart.upperBound..<source.endIndex
        ))
        let willOpenBlock = source[willOpenStart.lowerBound..<didCloseStart.lowerBound]
        XCTAssertTrue(willOpenBlock.contains("trackedMenus.insert(ObjectIdentifier(menu))"))

        let didCloseEnd = try XCTUnwrap(source.range(
            of: "\n    @objc func checkForUpdates()",
            range: didCloseStart.upperBound..<source.endIndex
        ))
        let didCloseBlock = source[didCloseStart.lowerBound..<didCloseEnd.lowerBound]
        XCTAssertTrue(didCloseBlock.contains("trackedMenus.remove(ObjectIdentifier(menu))"))
        XCTAssertTrue(didCloseBlock.contains("refreshMigrationImportEligibility()"))
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
        XCTAssertTrue(automaticGateBlock.contains("AutomaticUpdatePresentationState("))
        XCTAssertTrue(automaticGateBlock.contains("isMigrationMaintenanceActive: isMigrationMaintenanceActive"))
        XCTAssertTrue(automaticGateBlock.contains("isRecordingHotkey: isRecordingHotkey"))
        XCTAssertTrue(automaticGateBlock.contains("migrationWorkflowsAreIdle: migrationWorkflowsAreIdle"))
        XCTAssertTrue(automaticGateBlock.contains("isSelectingMigrationSource: migrationPresentationModel.phase == .selecting"))
        XCTAssertTrue(automaticGateBlock.contains("hasModalWindow: NSApp.modalWindow != nil"))
        XCTAssertTrue(automaticGateBlock.contains("isSelectionPanelVisible: selectionActionWindowController.isPanelVisible"))
        XCTAssertTrue(automaticGateBlock.contains("isMenuTracking: !trackedMenus.isEmpty"))
        XCTAssertTrue(automaticGateBlock.contains("isUpdateAlertPresenting: updateCheckAlertPresenter.isPresentingAlert"))
        XCTAssertTrue(automaticGateBlock.contains(").canPresent"))

        let requestMigrationStart = try XCTUnwrap(source.range(
            of: "\n    private func requestAssistedMigrationImport",
            range: refreshStart.upperBound..<source.endIndex
        ))
        let refreshBlock = source[refreshStart.lowerBound..<requestMigrationStart.lowerBound]
        XCTAssertTrue(refreshBlock.contains("migrationPresentationModel.setWorkflowsIdle("))
        XCTAssertTrue(refreshBlock.contains(
            "automaticUpdatePresentationGate.schedule()"
        ))
        XCTAssertFalse(refreshBlock.contains("presentPendingAutomaticUpdateIfPossible()"))

        XCTAssertEqual(
            source.components(separatedBy: "private lazy var automaticUpdatePresentationGate").count - 1,
            1
        )
        XCTAssertEqual(
            source.components(separatedBy: "AutomaticUpdatePresentationGate(").count - 1,
            1
        )
        XCTAssertEqual(
            source.components(separatedBy: "updateCheckCoordinator.presentPendingAutomaticUpdateIfPossible()").count - 1,
            1
        )
        let presentationGateStart = try XCTUnwrap(source.range(
            of: "private lazy var automaticUpdatePresentationGate"
        ))
        let updatePresenterStart = try XCTUnwrap(source.range(
            of: "private lazy var updateCheckAlertPresenter",
            range: presentationGateStart.upperBound..<source.endIndex
        ))
        let presentationGateBlock = source[
            presentationGateStart.lowerBound..<updatePresenterStart.lowerBound
        ]
        XCTAssertTrue(presentationGateBlock.contains("AutomaticUpdatePresentationGate("))
        XCTAssertTrue(presentationGateBlock.contains("canPresent: { [weak self] in"))
        XCTAssertTrue(presentationGateBlock.contains("self?.canPresentAutomaticUpdate ?? false"))
        XCTAssertTrue(presentationGateBlock.contains("present: { [weak self] in"))
        XCTAssertTrue(presentationGateBlock.contains(
            "self?.updateCheckCoordinator.presentPendingAutomaticUpdateIfPossible()"
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
        let availabilityGuard = try XCTUnwrap(checkActionBlock.range(of: "guard isUpdateCheckAvailable else"))
        let menuRefresh = try XCTUnwrap(checkActionBlock.range(of: "refreshUpdateCheckMenuItems()"))
        let manualCheck = try XCTUnwrap(checkActionBlock.range(of: "updateCheckCoordinator.checkManually()"))
        XCTAssertLessThan(availabilityGuard.lowerBound, menuRefresh.lowerBound)
        XCTAssertLessThan(menuRefresh.lowerBound, manualCheck.lowerBound)
        XCTAssertTrue(checkActionBlock.contains("updateCheckCoordinator.checkManually()"))
    }

    func testUpdateEligibilityRefreshesAfterMigrationSelectionAndSelectionPanelHide() throws {
        let source = try appCoordinatorSource()
        let migrationStart = try XCTUnwrap(source.range(of: "private func requestAssistedMigrationImport()"))
        let maintenanceStart = try XCTUnwrap(source.range(
            of: "\n    private func enterMigrationMaintenance()",
            range: migrationStart.upperBound..<source.endIndex
        ))
        let migrationBlock = source[migrationStart.lowerBound..<maintenanceStart.lowerBound]
        let beginSelecting = try XCTUnwrap(migrationBlock.range(
            of: "migrationPresentationModel.beginSelecting()"
        ))
        let finalRefresh = try XCTUnwrap(migrationBlock.range(
            of: "defer { refreshMigrationImportEligibility() }",
            range: beginSelecting.upperBound..<migrationBlock.endIndex
        ))
        let panelBegin = try XCTUnwrap(migrationBlock.range(of: "await panel.begin()"))
        XCTAssertLessThan(beginSelecting.lowerBound, finalRefresh.lowerBound)
        XCTAssertLessThan(finalRefresh.lowerBound, panelBegin.lowerBound)

        let effectsStart = try XCTUnwrap(source.range(of: "private func handleSelectionActionEffects"))
        let dismissStart = try XCTUnwrap(source.range(
            of: "\n    private func handleSelectionDismissRequest",
            range: effectsStart.upperBound..<source.endIndex
        ))
        let effectsBlock = source[effectsStart.lowerBound..<dismissStart.lowerBound]
        let hideEffect = try XCTUnwrap(effectsBlock.range(of: "case .hidePanel:"))
        let cancelWork = try XCTUnwrap(effectsBlock.range(
            of: "\n            case .cancelWork:",
            range: hideEffect.upperBound..<effectsBlock.endIndex
        ))
        let hideBlock = effectsBlock[hideEffect.lowerBound..<cancelWork.lowerBound]
        let hidePanel = try XCTUnwrap(hideBlock.range(
            of: "selectionActionWindowController.hidePanel()"
        ))
        let refresh = try XCTUnwrap(hideBlock.range(of: "refreshMigrationImportEligibility()"))
        XCTAssertLessThan(hidePanel.lowerBound, refresh.lowerBound)
    }

    func testUpdateWiringDoesNotAddUpdaterFrameworkOrInstallBehavior() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let packageSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let sourcesRoot = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        let sourceURLs = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourcesRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            )?.allObjects as? [URL]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        let forbiddenTokens = [
            "Sparkle",
            "SUUpdater",
            "SPUStandardUpdaterController",
            "downloadUpdate",
            "installUpdate",
            "downloadAndInstall",
        ]

        for sourceURL in [packageRoot.appendingPathComponent("Package.swift")] + sourceURLs {
            let source = sourceURL == packageRoot.appendingPathComponent("Package.swift")
                ? packageSource
                : try String(contentsOf: sourceURL, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(source.contains(token), "\(sourceURL.path) must not contain \(token)")
            }
        }
    }

    func testConfigurationReloadsWindowOwnedDictationWithoutGlobalVoiceInfrastructure() throws {
        let source = try appCoordinatorSource()
        let removedNames = [
            ["Voice", "Input", "Coordinator"].joined(),
            ["Voice", "Shortcut", "Monitor"].joined(),
            ["Voice", "Status", "Window", "Controller"].joined(),
        ]

        XCTAssertTrue(source.contains("windowController.reloadDictationConfiguration()"))
        for removedName in removedNames {
            XCTAssertFalse(source.contains(removedName), "Retired global type remains: \(removedName)")
        }
        XCTAssertFalse(source.contains("configure" + "VoiceInput"))
        XCTAssertFalse(source.contains(["make", "Voice", "Input", "Coordinator"].joined()))
    }

    func testShutdownJoinsDictationBeforeRemovingObserversAndTerminationWaitsForShutdown() throws {
        let source = try appCoordinatorSource()
        let stopStart = try XCTUnwrap(source.range(of: "func stop() async"))
        let menuStart = try XCTUnwrap(source.range(
            of: "private func configureMainMenu",
            range: stopStart.upperBound..<source.endIndex
        ))
        let stopBlock = source[stopStart.lowerBound..<menuStart.lowerBound]
        let cancel = try XCTUnwrap(stopBlock.range(of: "await windowController.cancelDictationAndWait()"))
        let observers = try XCTUnwrap(stopBlock.range(of: "if let configObserver"))

        XCTAssertLessThan(cancel.lowerBound, observers.lowerBound)
        XCTAssertTrue(source.contains("func applicationShouldTerminate"))
        XCTAssertTrue(source.contains("return .terminateLater"))
        XCTAssertTrue(source.contains("await coordinator.stop()"))
        XCTAssertTrue(source.contains("reply(toApplicationShouldTerminate: true)"))
        XCTAssertFalse(source.contains("return .terminateNow"))
        XCTAssertFalse(source.contains("func applicationWillTerminate"))
    }

    func testShutdownRejectsNewPopoverAndDictationConfigurationWorkBeforeAwaitingCleanup() throws {
        let source = try appCoordinatorSource()
        let stopStart = try XCTUnwrap(source.range(of: "func stop() async"))
        let menuStart = try XCTUnwrap(source.range(
            of: "private func configureMainMenu",
            range: stopStart.upperBound..<source.endIndex
        ))
        let stopBlock = source[stopStart.lowerBound..<menuStart.lowerBound]
        let stoppingAssignment = try XCTUnwrap(stopBlock.range(of: "isStopping = true"))
        let cancellation = try XCTUnwrap(stopBlock.range(
            of: "await windowController.cancelDictationAndWait()"
        ))
        let openStart = try XCTUnwrap(source.range(of: "@objc func openPopover()"))
        let settingsStart = try XCTUnwrap(source.range(
            of: "@objc func openSettings()",
            range: openStart.upperBound..<source.endIndex
        ))
        let openBlock = source[openStart.lowerBound..<settingsStart.lowerBound]
        let configObserverStart = try XCTUnwrap(source.range(of: "configObserver ="))
        let accessibilityObserverStart = try XCTUnwrap(source.range(
            of: "accessibilityObserver =",
            range: configObserverStart.upperBound..<source.endIndex
        ))
        let configObserverBlock = source[configObserverStart.lowerBound..<accessibilityObserverStart.lowerBound]

        XCTAssertTrue(source.contains("private var isStopping = false"))
        XCTAssertLessThan(stoppingAssignment.lowerBound, cancellation.lowerBound)
        XCTAssertTrue(openBlock.contains("guard !isStopping"))
        XCTAssertTrue(configObserverBlock.contains("!self.isStopping"))
    }

    func testAudioRecorderHasNoLegacyNoResultStartWrapper() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/AudioRecorder.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("func start(microphoneDeviceID: String?) async throws"))
        XCTAssertTrue(source.contains("func startStreaming("))
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
