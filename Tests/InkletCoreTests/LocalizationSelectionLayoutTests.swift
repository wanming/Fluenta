import AppKit
import SwiftUI
import XCTest
@testable import Inklet
import InkletCore

@MainActor
final class LocalizationSelectionLayoutTests: XCTestCase {
    func testMenuFitsItsLocalizedLabelsWithoutUnusedFixedWidth() {
        for language in InterfaceLanguage.allCases where language != .system {
            withLanguage(language) {
                let size = measure(.menu(errorMessage: nil, feedback: nil))
                let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
                let titles = ["selection.action.translate", "selection.action.pronounce"]
                let titleWidth = titles.reduce(CGFloat.zero) {
                    $0 + (L10n.text($1) as NSString).size(withAttributes: [.font: font]).width
                }
                // Two 15pt icons, 6pt icon gaps, 18pt button padding,
                // a 6pt button gap, and 16pt panel padding.
                XCTAssertEqual(size.width, titleWidth + 100, accuracy: 2, language.rawValue)
                XCTAssertEqual(size.height, 46, accuracy: 1, language.rawValue)
                XCTAssertLessThanOrEqual(size.width, 320, language.rawValue)
            }
        }
    }

    func testMenuFeedbackKeepsTheSameSizeInEveryLanguage() {
        for language in InterfaceLanguage.allCases where language != .system {
            withLanguage(language) {
                let idle = measure(.menu(errorMessage: nil, feedback: nil))
                for feedback: SelectionActionFeedback in [
                    .loadingMenuTranslation, .loadingMenuPronunciation, .playingMenuPronunciation
                ] {
                    let size = measure(.menu(errorMessage: nil, feedback: feedback))
                    XCTAssertEqual(size.width, idle.width, accuracy: 1, language.rawValue)
                    XCTAssertEqual(size.height, idle.height, accuracy: 1, language.rawValue)
                }
            }
        }
    }

    func testLongTranslationSupportsTheMinimumResizablePanelWidth() {
        withLanguage(.german) {
            let text = String(repeating: "A longer translation. ", count: 30)
            let host = NSHostingController(rootView: makeView(.translationResult(text, errorMessage: nil, feedback: nil)))
            let size = host.sizeThatFits(in: NSSize(width: 300, height: 180))
            XCTAssertLessThanOrEqual(size.width, 300)
        }
    }

    func testLanguageChangeResizesAnExistingMenu() async throws {
        let key = InkletPreferenceKeys.interfaceLanguage
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(InterfaceLanguage.german.rawValue, forKey: key)
        let controller = SelectionActionWindowController()
        let germanWidth = try XCTUnwrap(controller.window).frame.width

        UserDefaults.standard.set(InterfaceLanguage.simplifiedChinese.rawValue, forKey: key)
        NotificationCenter.default.post(name: .inkletLanguageDidChange, object: nil)
        let expected = measure(.menu(errorMessage: nil, feedback: nil))
        for _ in 0..<20 {
            if abs((controller.window?.frame.width ?? 0) - expected.width) < 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertLessThan(expected.width, germanWidth)
        XCTAssertEqual(controller.window?.frame.width ?? 0, expected.width, accuracy: 1)
        XCTAssertEqual(controller.window?.title, L10n.text("settings.section.selectionActions"))
        XCTAssertFalse(controller.isPanelVisible)
    }

    func testSelectionSnapshotsInEveryLanguage() throws {
        for language in InterfaceLanguage.allCases where language != .system {
            try withLanguage(language) {
                for (name, state): (String, SelectionActionViewState) in [
                    ("menu", .menu(errorMessage: nil, feedback: nil)),
                    ("loading", .menu(errorMessage: nil, feedback: .loadingMenuTranslation)),
                    ("playing", .menu(errorMessage: nil, feedback: .playingMenuPronunciation)),
                    ("error", .translationError(L10n.text("selection.action.translationFailed"))),
                    ("result", .translationResult("A short translation.\n一段简短的翻译。", errorMessage: nil, feedback: .copiedTranslation))
                ] {
                    try LocalizationSnapshot.record(
                        makeView(state), name: "selection-\(name)-\(language.localeIdentifier)",
                        size: name == "result" ? NSSize(width: 320, height: 220) : nil
                    )
                }
            }
        }
    }

    private func measure(_ state: SelectionActionViewState) -> NSSize {
        NSHostingView(rootView: makeView(state)).fittingSize
    }

    private func makeView(_ state: SelectionActionViewState) -> SelectionActionView {
        SelectionActionView(
            state: state,
            onTranslate: {}, onPronounce: {}, onPronounceOriginal: {},
            onPronounceTranslation: {}, onCopyTranslation: {}, onRetryTranslation: {}
        )
    }

    private func withLanguage(_ language: InterfaceLanguage, body: () throws -> Void) rethrows {
        let key = InkletPreferenceKeys.interfaceLanguage
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(language.rawValue, forKey: key)
        try body()
    }
}
