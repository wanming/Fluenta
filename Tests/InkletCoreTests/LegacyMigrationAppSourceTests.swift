import XCTest

final class LegacyMigrationAppSourceTests: XCTestCase {
    func testPresentationModelDefinesMaintenancePhasesAndDerivedState() throws {
        let source = try appSource(named: "LegacyMigrationPresentationModel.swift")

        for phase in [
            "case hidden",
            "case needsImport",
            "case selecting",
            "case importing",
            "case failed",
            "case relaunching",
            "case relaunchFailed",
        ] {
            XCTAssertTrue(source.contains(phase), "Missing presentation phase: \(phase)")
        }
        XCTAssertTrue(source.contains("@Published private(set) var phase"))
        XCTAssertTrue(source.contains("@Published private(set) var outcome"))
        XCTAssertTrue(source.contains("var isSettingsReadOnly: Bool"))
        XCTAssertTrue(source.contains("phase == .importing"))
        XCTAssertTrue(source.contains("phase == .relaunching"))
        XCTAssertTrue(source.contains("phase == .relaunchFailed"))
        XCTAssertTrue(source.contains("var canRequestImport: Bool"))
        XCTAssertTrue(source.contains("phase == .needsImport"))
        XCTAssertTrue(source.contains("phase == .failed"))
        XCTAssertTrue(source.contains("func update(with outcome: LegacySandboxMigrationOutcome)"))
        XCTAssertTrue(source.contains("case invalidSelection"))
        XCTAssertTrue(source.contains("func failInvalidSelection()"))
        XCTAssertTrue(source.contains("private var selectionReturnPhase"))
        XCTAssertTrue(source.contains("phase = selectionReturnPhase"))
    }

    func testSettingsRetainsOneModelAndFreezesAutosaveDuringMigration() throws {
        let controller = try appSource(named: "SettingsWindowController.swift")
        let view = try appSource(named: "SettingsView.swift")
        let compactController = controller.filter { !$0.isWhitespace }
        let pronunciationPreview = try sourceScope(
            startingAt: "func previewPronunciationVoice()",
            endingBefore: "func resetSelectionTranslationPrompt()",
            in: view
        )

        XCTAssertTrue(controller.contains("private let model: SettingsViewModel"))
        XCTAssertTrue(compactController.contains("SettingsView(model:model"))
        XCTAssertFalse(controller.contains("SettingsView(initialSection: section, historyStore:"))
        XCTAssertTrue(controller.contains("func flushPendingEdits() -> Bool"))
        XCTAssertTrue(controller.contains("func setMigrationMaintenanceActive(_ isActive: Bool)"))
        XCTAssertTrue(controller.contains("func waitForMigrationMaintenanceQuiescence() async"))
        XCTAssertTrue(controller.contains("func showMigrationNotice()"))

        XCTAssertTrue(view.contains("func flushPendingEdits() -> Bool"))
        XCTAssertTrue(view.contains("@discardableResult\n    func save() -> Bool"))
        XCTAssertTrue(view.contains("func setMigrationMaintenanceActive(_ isActive: Bool)"))
        XCTAssertTrue(view.contains("autoSaveCancellable?.cancel()"))
        XCTAssertTrue(view.contains("pronunciationPreviewTasks.values.forEach { $0.cancel() }"))
        XCTAssertTrue(view.contains("pronunciationPreviewPlaybackService.stop()"))
        XCTAssertTrue(view.contains("modelCatalogRefreshTask?.cancel()"))
        XCTAssertTrue(view.contains("func waitForMigrationMaintenanceQuiescence() async"))
        let clearHistory = try sourceScope(
            startingAt: "func clearHistory()",
            endingBefore: "func refreshMicrophoneOptions()",
            in: view
        )
        XCTAssertTrue(clearHistory.contains("guard !isMigrationMaintenanceActive else { return }"))
        XCTAssertTrue(view.contains(".disabled(model.isMigrationMaintenanceActive)"))
        XCTAssertTrue(view.contains("migrationNoticeCard"))
        XCTAssertTrue(view.contains("ProgressView()"))
        let migrationAction = try sourceScope(
            startingAt: "private var migrationPrimaryAction",
            endingBefore: "private var writeAssistantControls",
            in: view
        )
        XCTAssertEqual(migrationAction.components(separatedBy: "Button(action: action)").count - 1, 1)
        XCTAssertTrue(migrationAction.contains("Label {"))
        XCTAssertTrue(migrationAction.contains("if showsProgress"))
        XCTAssertTrue(migrationAction.contains("ProgressView()"))
        XCTAssertTrue(migrationAction.contains(".frame(width: 168, height: 28)"))
        XCTAssertTrue(migrationAction.contains("isEnabled: false"))
        XCTAssertTrue(view.contains("legacyMigration.action.importOldData"))
        XCTAssertTrue(view.contains("legacyMigration.import.invalidSelection"))
        XCTAssertTrue(view.contains("legacyMigration.import.partialFailure"))
        try assertTokensAppearInOrder(
            [
                "let audioData = try await provider.speechAudio",
                "guard !Task.isCancelled",
                "pronunciationPreviewTaskID == taskID",
                "!isMigrationMaintenanceActive",
                "pronunciationPreviewPlaybackService.play",
            ],
            in: String(pronunciationPreview)
        )
    }

    func testAssistedImportUsesOnlyCurrentProcessPanelGrantAndRelaunchesSafely() throws {
        let source = try appSource(named: "AppCoordinator.swift")

        XCTAssertTrue(source.contains("NSOpenPanel()"))
        XCTAssertTrue(source.contains("canChooseDirectories = true"))
        XCTAssertTrue(source.contains("canChooseFiles = false"))
        XCTAssertTrue(source.contains("allowsMultipleSelection = false"))
        XCTAssertTrue(source.contains("startAccessingSecurityScopedResource()"))
        XCTAssertTrue(source.contains("stopAccessingSecurityScopedResource()"))
        try assertTokensAppearInOrder(
            [
                "validateUserSelectedDataRoot",
                "migrateUserSelectedData",
                "createsNewApplicationInstance = true",
            ],
            in: source
        )
        XCTAssertTrue(source.contains("Task.detached"))
        XCTAssertTrue(source.contains("migrationPresentationModel.failInvalidSelection()"))
        XCTAssertTrue(source.contains("NSWorkspace.OpenConfiguration()"))
        XCTAssertTrue(source.contains("Bundle.main.bundleURL"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("bookmarkData"))
        XCTAssertFalse(source.contains("set(selected"))
        XCTAssertFalse(source.contains("UserDefaults.standard.set(selected"))
    }

    func testAssistedImportStopsWhenPendingSettingsCannotBeFlushed() throws {
        let source = try appSource(named: "AppCoordinator.swift")
        let importFlow = try sourceScope(
            startingAt: "private func requestAssistedMigrationImport() async",
            endingBefore: "private func enterMigrationMaintenance() async",
            in: source
        )

        try assertTokensAppearInOrder(
            [
                "guard settingsController.flushPendingEdits() else",
                "migrationPresentationModel.failImport()",
                "refreshMigrationImportEligibility()",
                "return",
                "migrationPresentationModel.beginImporting()",
                "migrateUserSelectedData",
            ],
            in: String(importFlow)
        )
    }

    func testWindowOperationCompletionRefreshesMigrationEligibility() throws {
        let source = try appSource(named: "AppCoordinator.swift")
        let initializer = try sourceScope(
            startingAt: "init(",
            endingBefore: "func start()",
            in: source
        )

        XCTAssertTrue(initializer.contains("windowController.onBusyChange = { [weak self] _ in"))
        XCTAssertTrue(initializer.contains("guard let self, !self.isStopping else { return }"))
        XCTAssertTrue(initializer.contains("self.refreshMigrationImportEligibility()"))
    }

    func testCoordinatorFreezesAllMutationSurfacesAndRechecksBusyState() throws {
        let source = try appSource(named: "AppCoordinator.swift")
        let importFlow = try sourceScope(
            startingAt: "private func requestAssistedMigrationImport() async",
            endingBefore: "private func enterMigrationMaintenance() async",
            in: source
        )
        let maintenanceEntry = try sourceScope(
            startingAt: "private func enterMigrationMaintenance() async",
            endingBefore: "private func leaveMigrationMaintenance()",
            in: source
        )
        let copyTrigger = try sourceScope(
            startingAt: "private func handleSelectionActionCopyTrigger",
            endingBefore: "private func handleSelectionActionEffects",
            in: source
        )
        let scheduledRead = try sourceScope(
            startingAt: "private func completeScheduledSelectionRead",
            endingBefore: "private func readSelectedTextForAutomaticSelection",
            in: source
        )
        let translation = try sourceScope(
            startingAt: "private func translateCurrentSelection",
            endingBefore: "private func pronounceCurrentSelection",
            in: source
        )
        let pronunciation = try sourceScope(
            startingAt: "private func pronounceSelectionText",
            endingBefore: "private func restoreSelectionPronunciationReturnState",
            in: source
        )
        let pronunciationRestore = try sourceScope(
            startingAt: "private func restoreSelectionPronunciationReturnState",
            endingBefore: "private func showSelectionPronunciationError",
            in: source
        )

        XCTAssertTrue(source.contains("private var isMigrationMaintenanceActive"))
        XCTAssertTrue(source.contains("windowController.isBusy"))
        XCTAssertTrue(source.contains("settingsController.isMigrationWorkflowIdle"))
        XCTAssertTrue(source.contains("settingsController.onMigrationWorkflowIdleChange"))
        XCTAssertTrue(source.contains("selectionReadTask == nil"))
        XCTAssertTrue(source.contains("selectionTranslationTask == nil"))
        XCTAssertTrue(source.contains("selectionTTSTask == nil"))
        XCTAssertTrue(source.contains("!isSelectionSpeechPlaying"))
        XCTAssertTrue(source.contains("guard canRequestAssistedMigration"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "guard canRequestAssistedMigration").count - 1,
            2
        )
        XCTAssertTrue(source.contains("hotkeyManager.unregister()"))
        XCTAssertTrue(source.contains("selectionActionMonitor.stop()"))
        XCTAssertTrue(source.contains("await settingsController.waitForMigrationMaintenanceQuiescence()"))
        XCTAssertTrue(source.contains("await windowController.cancelForMigrationMaintenance()"))
        XCTAssertTrue(source.contains("selectionReadTask?.cancel()"))
        XCTAssertTrue(source.contains("selectionTranslationTask?.cancel()"))
        XCTAssertTrue(source.contains("selectionTTSTask?.cancel()"))
        XCTAssertTrue(source.contains("speechPlaybackService.stop()"))
        XCTAssertTrue(source.contains("guard !isStopping, !isMigrationMaintenanceActive"))
        XCTAssertTrue(copyTrigger.contains("let task = Task"))
        XCTAssertTrue(copyTrigger.contains("selectionTaskRegistry.register(task, id: taskID)"))
        try assertTokensAppearInOrder(
            [
                "settingsController.setMigrationMaintenanceActive(true)",
                "await enterMigrationMaintenance()",
                "Task.detached",
            ],
            in: String(importFlow)
        )
        try assertTokensAppearInOrder(
            [
                "isMigrationMaintenanceActive = true",
                "await windowController.cancelForMigrationMaintenance()",
                "await settingsController.waitForMigrationMaintenanceQuiescence()",
            ],
            in: String(maintenanceEntry)
        )
        try assertTokensAppearInOrder(
            [
                "readSelectedTextForAutomaticSelection()",
                "guard !Task.isCancelled, !isStopping, !isMigrationMaintenanceActive else { return }",
                "handleSelectionActionEffects",
            ],
            in: String(scheduledRead)
        )
        try assertTokensAppearInOrder(
            [
                "let translated = try await service.translate",
                "guard !Task.isCancelled, !isStopping, !isMigrationMaintenanceActive else { return }",
                "historyStore.append",
            ],
            in: String(translation)
        )
        try assertTokensAppearInOrder(
            [
                "let audioData = try await provider.speechAudio",
                "guard !Task.isCancelled, !isStopping, !isMigrationMaintenanceActive else { return }",
                "speechPlaybackService.play",
            ],
            in: String(pronunciation)
        )
        XCTAssertTrue(
            pronunciationRestore.contains("guard !isStopping, !isMigrationMaintenanceActive else { return }")
        )
    }

    func testPopoverExposesBusyAndMaintenanceCancellation() throws {
        let view = try appSource(named: "InkletPopoverView.swift")
        let controller = try appSource(named: "InkletPopoverWindowController.swift")

        XCTAssertTrue(view.contains("var isBusy: Bool"))
        XCTAssertTrue(view.contains("func cancelForMigrationMaintenance()"))
        XCTAssertTrue(view.contains("transformationTask?.cancel()"))
        XCTAssertTrue(view.contains("sessionID += 1"))
        XCTAssertTrue(controller.contains("var isBusy: Bool"))
        XCTAssertTrue(controller.contains("func cancelForMigrationMaintenance() async"))
        XCTAssertTrue(controller.contains("func cancelDictationAndWait() async"))
        XCTAssertTrue(controller.contains("model.cancelForMigrationMaintenance()"))
        XCTAssertTrue(controller.contains("await dictationCoordinator.cancelAndWait()"))
        XCTAssertTrue(controller.contains("window?.orderOut(nil)"))
    }

    func testMigrationFinishesBeforeAppKitAndDelegateConstruction() throws {
        let source = try appSource(named: "main.swift")

        try assertTokensAppearInOrder(
            [
                "try InkletStoragePaths.current()",
                "LegacySandboxDataMigrator.live(storagePaths: storagePaths)",
                "migrator.migrateAutomatically()",
                "NSApplication.shared",
                "AppDelegate(",
            ],
            in: source
        )

        let beforeMigration = try sourcePrefix(
            endingBefore: "migrator.migrateAutomatically()",
            in: source
        )
        XCTAssertFalse(beforeMigration.contains("NSApplication.shared"))
        XCTAssertFalse(beforeMigration.contains("AppDelegate("))
    }

    func testStartupFailsClosedWithoutAValidSupportedAppBundleIdentifier() throws {
        let source = try appSource(named: "main.swift")
        let pathResolution = try sourceScope(
            startingAt: "let storagePaths",
            endingBefore: "let migrator",
            in: source
        )

        XCTAssertTrue(pathResolution.contains("try InkletStoragePaths.current()"))
        XCTAssertTrue(pathResolution.contains("catch {"))
        XCTAssertTrue(
            pathResolution.contains(
                "preconditionFailure(\"Unable to resolve Inklet storage paths\")"
            )
        )
        XCTAssertFalse(
            pathResolution.contains("catch InkletStoragePathsError.missingBundleIdentifier")
        )
        XCTAssertFalse(pathResolution.contains("currentOrLocalDevelopment"))
        XCTAssertFalse(pathResolution.contains("\\(error)"))
        XCTAssertTrue(pathResolution.contains("switch storagePaths.bundleIdentifier"))
        XCTAssertTrue(pathResolution.contains("InkletStoragePaths.productionBundleIdentifier"))
        XCTAssertTrue(pathResolution.contains("InkletStoragePaths.localBundleIdentifier"))
        XCTAssertTrue(pathResolution.contains("default:"))
        XCTAssertTrue(
            pathResolution.contains(
                "preconditionFailure(\"Unsupported Inklet bundle identifier\")"
            )
        )
    }

    func testAppDelegateUsesExplicitMigrationDependencies() throws {
        let source = try appSource(named: "AppCoordinator.swift")
        let delegate = try sourceScope(
            startingAt: "final class AppDelegate",
            endingBefore: "private enum SelectionPronunciationReturnState",
            in: source
        )

        XCTAssertFalse(delegate.contains("private let coordinator = AppCoordinator()"))
        XCTAssertTrue(delegate.contains("private let coordinator: AppCoordinator"))

        let initializer = try sourceScope(
            startingAt: "init(",
            endingBefore: "func applicationDidFinishLaunching",
            in: delegate
        )
        XCTAssertTrue(initializer.contains("migrationOutcome: LegacySandboxMigrationOutcome"))
        XCTAssertTrue(initializer.contains("migrator: LegacySandboxDataMigrator"))
        XCTAssertTrue(initializer.contains("storagePaths: InkletStoragePaths"))
        XCTAssertTrue(initializer.contains("self.coordinator = AppCoordinator("))
        XCTAssertTrue(initializer.contains("migrationOutcome: migrationOutcome"))
        XCTAssertTrue(initializer.contains("migrator: migrator"))
        XCTAssertTrue(initializer.contains("storagePaths: storagePaths"))
    }

    func testCoordinatorRetainsMigrationStateAndInjectsOneStoragePathGraph() throws {
        let source = try appSource(named: "AppCoordinator.swift")
        let coordinator = try sourceScope(
            startingAt: "final class AppCoordinator",
            endingBefore: nil,
            in: source
        )

        XCTAssertTrue(coordinator.contains("private let migrationOutcome: LegacySandboxMigrationOutcome"))
        XCTAssertTrue(coordinator.contains("private let migrator: LegacySandboxDataMigrator"))
        XCTAssertTrue(coordinator.contains("private let storagePaths: InkletStoragePaths"))

        let initializer = try sourceScope(
            startingAt: "init(",
            endingBefore: "func start()",
            in: coordinator
        )
        XCTAssertTrue(initializer.contains("migrationOutcome: LegacySandboxMigrationOutcome"))
        XCTAssertTrue(initializer.contains("migrator: LegacySandboxDataMigrator"))
        XCTAssertTrue(initializer.contains("storagePaths: InkletStoragePaths"))
        XCTAssertTrue(initializer.contains("self.migrationOutcome = migrationOutcome"))
        XCTAssertTrue(initializer.contains("self.migrator = migrator"))
        XCTAssertTrue(initializer.contains("self.storagePaths = storagePaths"))
        XCTAssertTrue(initializer.contains("JSONLHistoryStore(fileURL: storagePaths.historyFileURL)"))
        let compactSettingsInitializer = initializer.filter { !$0.isWhitespace }
        XCTAssertTrue(compactSettingsInitializer.contains(
            "InkletPopoverWindowController(historyStore:historyStore,configStore:configStore,apiKeyStore:apiKeyStore)"
        ))
        XCTAssertTrue(compactSettingsInitializer.contains(
            "SettingsWindowController(historyStore:historyStore,migrationPresentationModel:migrationPresentationModel)"
        ))
        let compactInitializer = initializer.filter { !$0.isWhitespace }
        XCTAssertTrue(
            compactInitializer.contains(
                "JSONSelectionTranslationCache(fileURL:storagePaths.translationCacheFileURL)"
            )
        )
        XCTAssertTrue(
            initializer.contains(
                "SelectionActionDiagnostics.configure(fileURL: storagePaths.selectionDiagnosticsFileURL)"
            )
        )
        XCTAssertFalse(initializer.contains("InkletStoragePaths.current"))
        XCTAssertFalse(coordinator.contains("JSONLHistoryStore()"))
        XCTAssertFalse(coordinator.contains("JSONSelectionTranslationCache()"))
    }

    func testDiagnosticsUseOnlyTheConfiguredStoragePath() throws {
        let source = try appSource(named: "SelectionActionDiagnostics.swift")

        XCTAssertTrue(source.contains("@MainActor"))
        XCTAssertTrue(source.contains("static func configure(fileURL:"))
        XCTAssertTrue(source.contains("guard let url = fileURL else"))
        XCTAssertFalse(source.contains("InkletStoragePaths.current"))
        XCTAssertFalse(source.contains("currentOrLocalDevelopment"))
    }

    private func appSource(named fileName: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/InkletApp", isDirectory: true)
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func sourcePrefix(
        endingBefore endToken: String,
        in source: String
    ) throws -> Substring {
        let end = try XCTUnwrap(source.range(of: endToken))
        return source[source.startIndex..<end.lowerBound]
    }

    private func sourceScope(
        startingAt startToken: String,
        endingBefore endToken: String?,
        in source: some StringProtocol
    ) throws -> Substring {
        let text = String(source)
        let start = try XCTUnwrap(text.range(of: startToken))
        let endIndex: String.Index
        if let endToken {
            let end = try XCTUnwrap(
                text.range(of: endToken, range: start.upperBound..<text.endIndex)
            )
            endIndex = end.lowerBound
        } else {
            endIndex = text.endIndex
        }
        return text[start.lowerBound..<endIndex]
    }

    private func assertTokensAppearInOrder(
        _ tokens: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var searchStart = source.startIndex
        for token in tokens {
            let range = try XCTUnwrap(
                source.range(of: token, range: searchStart..<source.endIndex),
                "Missing startup token: \(token)",
                file: file,
                line: line
            )
            searchStart = range.upperBound
        }
    }
}
