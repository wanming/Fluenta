import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Inklet
@testable import InkletCore

@MainActor
final class LocalizationWritingLayoutTests: XCTestCase {
    func testMultilineErrorExpandsPopoverWithoutReducingEditorHeight() async throws {
        let model = try makeModel(shortcut: .disabled)
        model.commitMode(modeID: model.selectedModeID)
        let host = NSHostingView(rootView: InkletPopoverView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        await settle(host)
        let baseline = model.preferredPopoverHeight

        model.errorMessage = "The provider could not process the request.\nPlease check your provider settings.\nThen try again.\nYour draft is still available."
        await settle(host)

        XCTAssertGreaterThanOrEqual(model.preferredPopoverHeight - baseline, 70)
        XCTAssertEqual(model.sourceText, "")
    }

    func testExtremeErrorHasABoundedViewportAndDismissesToBaseline() async throws {
        let model = try makeModel(shortcut: .disabled)
        model.commitMode(modeID: model.selectedModeID)
        let host = NSHostingView(rootView: InkletPopoverView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        await settle(host)
        let baseline = model.preferredPopoverHeight
        let message = Array(repeating: "连接失败。The provider could not process the request.", count: 100).joined(separator: "\n")

        model.errorMessage = message
        await settle(host)

        XCTAssertLessThanOrEqual(model.preferredPopoverHeight - baseline, 121)
        XCTAssertEqual(model.errorMessage, message)
        model.errorMessage = nil
        await settle(host)
        XCTAssertEqual(model.preferredPopoverHeight, baseline, accuracy: 1)
    }

    func testLanguageNotificationRefreshesWritingViewWithoutResettingSession() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: InkletPreferenceKeys.interfaceLanguage)
        defer { UserDefaults.standard.set(previousLanguage, forKey: InkletPreferenceKeys.interfaceLanguage) }
        InkletLanguageStore.selectedLanguage = .english
        let model = try makeModel(shortcut: .rightCommand)
        model.commitMode(modeID: model.selectedModeID)
        model.updateSourceText("Keep this draft 中文")
        model.resultText = "Keep this result"
        let session = model.popoverSession
        let focusRevision = model.modeSearchFocusRevision
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }

        InkletLanguageStore.selectedLanguage = .german
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(model.sourceText, "Keep this draft 中文")
        XCTAssertEqual(model.resultText, "Keep this result")
        XCTAssertEqual(model.popoverSession, session)
        XCTAssertEqual(model.modeSearchFocusRevision, focusRevision)
        withExtendedLifetime(subscription) {}
    }

    func testLongLocalizedDictationStatusUsesASecondToolbarRow() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: InkletPreferenceKeys.interfaceLanguage)
        defer { UserDefaults.standard.set(previousLanguage, forKey: InkletPreferenceKeys.interfaceLanguage) }
        InkletLanguageStore.selectedLanguage = .german
        let model = try makeModel(shortcut: .rightCommand)
        model.commitMode(modeID: model.selectedModeID)
        let host = NSHostingView(rootView: InkletPopoverView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        await settle(host)

        try LocalizationSnapshot.record(host, name: "writing-german-toolbar")
        // Header, dividers and two editor rows occupy 112pt before the toolbar.
        XCTAssertGreaterThan(model.preferredPopoverHeight, 148)
    }

    func testLoadingKeepsTheExpandedToolbarHeight() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: InkletPreferenceKeys.interfaceLanguage)
        defer { UserDefaults.standard.set(previousLanguage, forKey: InkletPreferenceKeys.interfaceLanguage) }
        InkletLanguageStore.selectedLanguage = .german
        let model = try makeModel(shortcut: .rightCommand)
        model.commitMode(modeID: model.selectedModeID)
        let host = NSHostingView(rootView: InkletPopoverView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        await settle(host)
        let baseline = model.preferredPopoverHeight
        XCTAssertGreaterThan(baseline, 148)

        model.isTransforming = true
        await settle(host)
        XCTAssertEqual(model.preferredPopoverHeight, baseline)
        model.isTransforming = false
        model.isInserting = true
        await settle(host)
        XCTAssertEqual(model.preferredPopoverHeight, baseline)
    }

    func testAllLanguagesAndDictationStatesKeepErrorsAndToolbarWithinPopover() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: InkletPreferenceKeys.interfaceLanguage)
        defer { UserDefaults.standard.set(previousLanguage, forKey: InkletPreferenceKeys.interfaceLanguage) }
        let phases: [(String, WritingDictationCoordinator.Phase)] = [
            ("idle", .idle), ("connecting", .connecting), ("listening", .listening),
            ("fallback", .recordingForFallback), ("finalizing", .finalizing),
            ("recovering", .recovering), ("complete", .complete),
            ("failed", .failed("dictation.error.missingAPIKey")),
        ]

        for language in InterfaceLanguage.allCases where language != .system {
            InkletLanguageStore.selectedLanguage = language
            let model = try makeModel(shortcut: .rightCommand)
            let host = NSHostingView(rootView: InkletPopoverView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            await settle(host)
            try LocalizationSnapshot.record(host, name: "writing-\(language.rawValue)-picker")
            model.updateModeSearchQuery("No matching synthetic mode")
            await settle(host)
            XCTAssertEqual(model.preferredPopoverHeight, WritingModePickerView.preferredHeight(resultCount: 0))
            try LocalizationSnapshot.record(host, name: "writing-\(language.rawValue)-empty-picker")

            model.commitMode(modeID: model.selectedModeID)
            model.updateSourceText("A short draft. 这是一段中文草稿。")
            for (name, phase) in phases {
                model.setDictationPhase(phase)
                await settle(host)
                XCTAssertEqual(host.fittingSize.width, 600, "\(language): \(name)")
                XCTAssertEqual(host.fittingSize.height, model.preferredPopoverHeight, accuracy: 1)
                XCTAssertLessThanOrEqual(model.preferredPopoverHeight, 240, "\(language): \(name)")
                try LocalizationSnapshot.record(host, name: "writing-\(language.rawValue)-\(name)")
            }
            model.setDictationPhase(.idle)
            model.errorMessage = nil
            model.resultText = "A concise result. 一段简洁的结果。"
            await settle(host)
            let baseline = model.preferredPopoverHeight
            try LocalizationSnapshot.record(host, name: "writing-\(language.rawValue)-result")

            model.errorMessage = Array(repeating: L10n.text("dictation.error.missingAPIKey"), count: 4).joined(separator: "\n")
            await settle(host)
            XCTAssertGreaterThanOrEqual(model.preferredPopoverHeight - baseline, 70, language.rawValue)
            try LocalizationSnapshot.record(host, name: "writing-\(language.rawValue)-long-error")
            model.errorMessage = nil
            await settle(host)
            XCTAssertEqual(model.preferredPopoverHeight, baseline, accuracy: 1, language.rawValue)
        }
    }

    func testLanguageChangePreservesReplacementErrorAfterFailedDictation() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: InkletPreferenceKeys.interfaceLanguage)
        defer { UserDefaults.standard.set(previousLanguage, forKey: InkletPreferenceKeys.interfaceLanguage) }
        InkletLanguageStore.selectedLanguage = .english
        let model = try makeModel(shortcut: .rightCommand)
        model.setDictationPhase(.failed("dictation.error.missingAPIKey"))
        model.errorMessage = "A later provider error"

        InkletLanguageStore.selectedLanguage = .german
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(model.errorMessage, "A later provider error")
    }

    private func settle(_ host: NSHostingView<InkletPopoverView>) async {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            host.frame.size = host.fittingSize
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeModel(shortcut: VoiceInputConfig.Shortcut) throws -> InkletPopoverViewModel {
        let suiteName = "LocalizationWritingLayoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let configStore = UserDefaultsConfigStore(userDefaults: defaults)
        var config = AppConfig.defaultConfig()
        config.voiceInput.shortcut = shortcut
        try configStore.save(config)
        let model = InkletPopoverViewModel(
            configStore: configStore,
            writingModePreferenceStore: WritingModePreferenceStore(userDefaults: defaults)
        )
        model.resetForOpen(previousApplication: nil)
        return model
    }
}
