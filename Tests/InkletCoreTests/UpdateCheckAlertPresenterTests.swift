import AppKit
import Foundation
import XCTest
@testable import Inklet
@testable import InkletCore

@MainActor
final class UpdateCheckAlertPresenterTests: XCTestCase {
    nonisolated(unsafe) private var savedLanguage: String?

    override func setUp() {
        super.setUp()
        savedLanguage = UserDefaults.standard.string(forKey: InkletPreferenceKeys.interfaceLanguage)
        InkletLanguageStore.selectedLanguage = .english
    }

    override func tearDown() {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: InkletPreferenceKeys.interfaceLanguage)
        } else {
            UserDefaults.standard.removeObject(forKey: InkletPreferenceKeys.interfaceLanguage)
        }
        NotificationCenter.default.post(name: .inkletLanguageDidChange, object: nil)
        super.tearDown()
    }

    func testPresentUpdateAssemblesVersionDescriptionAndNotes() {
        let recorder = AlertRecorder(response: .alertSecondButtonReturn)
        let presenter = makePresenter(recorder: recorder)

        presenter.presentUpdate(
            release(name: "Faster dictation", notes: "Dictation is now noticeably faster."),
            currentVersion: "1.2.3 (45)"
        )

        XCTAssertEqual(recorder.contents, [
            .init(
                messageText: "An Inklet update is available",
                informativeText: "Latest: 2.0.0 (build 200)\n\nCurrent: 1.2.3 (45)\n\nFaster dictation\n\nDictation is now noticeably faster.",
                primaryButtonTitle: "View on GitHub",
                secondaryButtonTitle: "Later"
            ),
        ])
        XCTAssertTrue(recorder.openedURLs.isEmpty)
    }

    func testPresentUpdateOmitsWorkflowReleaseNameAndUsesNoNotesFallback() {
        let recorder = AlertRecorder(response: .alertSecondButtonReturn)
        let presenter = makePresenter(recorder: recorder)

        presenter.presentUpdate(release(name: "Inklet 2.0.0 (200)", notes: ""), currentVersion: "1.2.3")

        XCTAssertEqual(
            recorder.contents.first?.informativeText,
            "Latest: 2.0.0 (build 200)\n\nCurrent: 1.2.3\n\nView the release on GitHub for details."
        )

        let whitespaceRecorder = AlertRecorder(response: .alertSecondButtonReturn)
        makePresenter(recorder: whitespaceRecorder).presentUpdate(
            release(name: nil, notes: " \n\t "),
            currentVersion: "1.2.3"
        )
        XCTAssertEqual(
            whitespaceRecorder.contents.first?.informativeText,
            "Latest: 2.0.0 (build 200)\n\nCurrent: 1.2.3\n\nView the release on GitHub for details."
        )
    }

    func testPresentUpdateOpensOnlyItsExactPageURLForFirstResponse() {
        let firstRecorder = AlertRecorder(response: .alertFirstButtonReturn)
        makePresenter(recorder: firstRecorder).presentUpdate(release(), currentVersion: "1.2.3")
        XCTAssertEqual(firstRecorder.openedURLs, [release().pageURL])

        let laterRecorder = AlertRecorder(response: .alertSecondButtonReturn)
        makePresenter(recorder: laterRecorder).presentUpdate(release(), currentVersion: "1.2.3")
        XCTAssertTrue(laterRecorder.openedURLs.isEmpty)

        let otherRecorder = AlertRecorder(response: .cancel)
        makePresenter(recorder: otherRecorder).presentUpdate(release(), currentVersion: "1.2.3")
        XCTAssertTrue(otherRecorder.openedURLs.isEmpty)
    }

    func testPresentUpToDateShowsCurrentVersionWithoutOpeningURL() {
        let recorder = AlertRecorder(response: .alertFirstButtonReturn)
        makePresenter(recorder: recorder).presentUpToDate(currentVersion: "1.2.3 (45)")

        XCTAssertEqual(recorder.contents, [
            .init(
                messageText: "Inklet is up to date",
                informativeText: "You’re using 1.2.3 (45).",
                primaryButtonTitle: "Cancel",
                secondaryButtonTitle: nil
            ),
        ])
        XCTAssertTrue(recorder.openedURLs.isEmpty)
    }

    func testPresentFailureRetriesOnlyForFirstResponse() {
        var retries = 0
        let retryRecorder = AlertRecorder(response: .alertFirstButtonReturn)
        makePresenter(recorder: retryRecorder).presentFailure { retries += 1 }
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(retryRecorder.contents.first?.messageText, "Couldn’t check for updates")
        XCTAssertEqual(retryRecorder.contents.first?.informativeText, "Check your internet connection and try again.")
        XCTAssertEqual(retryRecorder.contents.first?.primaryButtonTitle, "Retry")
        XCTAssertEqual(retryRecorder.contents.first?.secondaryButtonTitle, "Cancel")

        let cancelRecorder = AlertRecorder(response: .alertSecondButtonReturn)
        makePresenter(recorder: cancelRecorder).presentFailure { retries += 1 }
        XCTAssertEqual(retries, 1)
    }

    func testProductionAlertRunnerActivatesApplicationBeforeShowingAlert() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/InkletApp/UpdateCheckAlertPresenter.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("NSApp.activate"))
    }

    private func makePresenter(recorder: AlertRecorder) -> UpdateCheckAlertPresenter {
        UpdateCheckAlertPresenter(
            alertRunner: { content in recorder.contents.append(content); return recorder.response },
            urlOpener: { recorder.openedURLs.append($0) }
        )
    }

    private func release(name: String? = "Faster dictation", notes: String = "Notes") -> InkletRelease {
        let tagName = "v2.0.0-200"
        return InkletRelease(
            version: try! InkletReleaseVersion(tagName: tagName),
            tagName: tagName,
            name: name,
            notes: notes,
            pageURL: URL(string: "https://github.com/wanming/Inklet/releases/tag/\(tagName)")!
        )
    }
}

@MainActor
private final class AlertRecorder {
    let response: NSApplication.ModalResponse
    var contents: [UpdateCheckAlertPresenter.AlertContent] = []
    var openedURLs: [URL] = []

    init(response: NSApplication.ModalResponse) {
        self.response = response
    }
}
