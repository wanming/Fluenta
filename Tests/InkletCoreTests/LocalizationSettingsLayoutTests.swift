import AppKit
import Security
import SwiftUI
import XCTest
@testable import Inklet
import InkletCore

@MainActor
final class LocalizationSettingsLayoutTests: XCTestCase {
    func testSettingsNavigationAllowsTranslatedTitlesToWrap() throws {
        let source = try appSource("SettingsView.swift")
        let start = try XCTUnwrap(source.range(of: "private var sidebar: some View"))
        let end = try XCTUnwrap(source.range(of: "private var detail: some View"))
        let sidebar = source[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(sidebar.contains(".lineLimit(1)"), "The 121 pt navigation label slot is narrower than even the English selected Selection Assistant title.")
    }

    func testSettingsInstructionalTextDoesNotHaveTruncationCaps() throws {
        let source = try appSource("SettingsView.swift")
        for (startToken, endToken) in [
            ("private func shortcutTitle", "private func permissionLine"),
            ("private func permissionLine", "private func privacyLine")
        ] {
            let start = try XCTUnwrap(source.range(of: startToken))
            let end = try XCTUnwrap(source.range(of: endToken))
            XCTAssertFalse(source[start.lowerBound..<end.lowerBound].contains(".lineLimit("), startToken)
        }
    }

    func testAboutWindowTitleRefreshesWithoutReplacingContent() async throws {
        let key = InkletPreferenceKeys.interfaceLanguage
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        InkletLanguageStore.selectedLanguage = .english
        let controller = AboutWindowController()
        let content = try XCTUnwrap(controller.window?.contentView)
        InkletLanguageStore.selectedLanguage = .simplifiedChinese
        for _ in 0..<20 {
            if controller.window?.title == L10n.text("app.menu.about") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.window?.title, L10n.text("app.menu.about"))
        XCTAssertTrue(controller.window?.contentView === content)
    }

    func testSidebarLabelsFitAtTheActualSettingsWidthInEveryLanguage() throws {
        for language in InterfaceLanguage.allCases where language != .system {
            try withLanguage(language) {
                var totalHeight: CGFloat = 0
                for section in SettingsSection.allCases {
                    let view = SettingsSidebarLabel(section: section, isSelected: true)
                        .frame(width: 172)
                    let size = NSHostingView(rootView: view).fittingSize
                    let textBounds = (section.title as NSString).boundingRect(
                        with: NSSize(width: 112, height: 1000),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
                    )
                    XCTAssertEqual(size.width, 172, accuracy: 1, "\(language): \(section)")
                    XCTAssertGreaterThanOrEqual(size.height, ceil(textBounds.height) + 15, "\(language): \(section)")
                    totalHeight += size.height + 2
                }
                XCTAssertLessThanOrEqual(totalHeight, 420, language.rawValue)
                try LocalizationSnapshot.record(
                    VStack(spacing: 2) {
                        ForEach(SettingsSection.allCases) { section in
                            SettingsSidebarLabel(section: section, isSelected: true)
                        }
                    }
                    .frame(width: 172),
                    name: "settings-sidebar-\(language.localeIdentifier)"
                )
            }
        }
    }

    func testAboutContentFitsAllLanguagesAndAdaptsItsHeight() throws {
        for language in InterfaceLanguage.allCases where language != .system {
            try withLanguage(language) {
                let view = AboutView()
                let size = NSHostingView(rootView: view).fittingSize
                XCTAssertEqual(size.width, 380, accuracy: 1, language.rawValue)
                XCTAssertGreaterThanOrEqual(size.height, 292, language.rawValue)
                XCTAssertLessThanOrEqual(size.height, 450, language.rawValue)
                try LocalizationSnapshot.record(view, name: "about-\(language.localeIdentifier)")
            }
        }
    }

    func testSettingsSnapshotsUseSyntheticDataInEveryLanguage() throws {
        guard ProcessInfo.processInfo.environment["INKLET_LOCALIZATION_SNAPSHOT_DIR"] != nil else { return }
        let suiteName = "InkletLocalizationSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let apiKeyStore = LocalAPIKeyStore { providerID in
            KeychainStore(service: "localization-fixture", account: providerID, client: LayoutFixtureKeychain())
        }
        for language in InterfaceLanguage.allCases where language != .system {
            try withLanguage(language) {
                let model = SettingsViewModel(
                    configStore: UserDefaultsConfigStore(userDefaults: defaults),
                    apiKeyStore: apiKeyStore,
                    modelCatalogService: ModelCatalogService(
                        userDefaults: defaults,
                        fetchData: { _ in Data("{}".utf8) }
                    ),
                    historyStore: LayoutFixtureHistory()
                )
                let migration = LegacyMigrationPresentationModel(outcome: LegacySandboxMigrationOutcome(
                    results: Dictionary(uniqueKeysWithValues: LegacyMigrationComponent.allCases.map {
                        ($0, .completed(changedDestination: false))
                    })
                ))
                for section in SettingsSection.allCases {
                    try LocalizationSnapshot.record(
                        SettingsView(model: model, migrationPresentationModel: migration, initialSection: section),
                        name: "settings-\(section.id.replacingOccurrences(of: " ", with: "-"))-\(language.localeIdentifier)",
                        size: NSSize(width: 860, height: 560)
                    )
                }
            }
        }
    }

    private func withLanguage(_ language: InterfaceLanguage, body: () throws -> Void) rethrows {
        let key = InkletPreferenceKeys.interfaceLanguage
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(language.rawValue, forKey: key)
        try body()
    }

    private func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/InkletApp/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private struct LayoutFixtureKeychain: KeychainClient {
    func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecItemNotFound }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { errSecSuccess }
    func add(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecSuccess }
    func delete(_ query: [String: Any]) -> OSStatus { errSecSuccess }
}

private struct LayoutFixtureHistory: HistoryStore {
    func load() -> [HistoryItem] {
        [HistoryItem(
            createdAt: Date(timeIntervalSince1970: 1_788_732_000),
            source: .selection,
            inputText: "A short example. 一段简短的示例。",
            outputText: "A clear result. 清晰的结果。"
        )]
    }
    func append(_ item: HistoryItem) {}
    func clear() {}
}
