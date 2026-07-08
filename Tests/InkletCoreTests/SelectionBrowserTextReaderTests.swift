import XCTest
@testable import InkletCore

final class SelectionBrowserTextReaderTests: XCTestCase {
    @MainActor
    func testReadsChromeSelectionUsingActiveTabJavaScript() async {
        var capturedScript = ""
        let reader = SelectionBrowserTextReader(appleScriptRunner: { script in
            capturedScript = script
            return .success("  selected text  ")
        })

        let result = await reader.readSelectedText(bundleIdentifier: "com.google.Chrome")

        XCTAssertEqual(result, .success("selected text"))
        XCTAssertTrue(capturedScript.contains(#"tell application id "com.google.Chrome""#))
        XCTAssertTrue(capturedScript.contains(#"tell active tab of front window"#))
        XCTAssertTrue(capturedScript.contains(#"execute javascript "window.getSelection().toString();""#))
    }

    @MainActor
    func testReadsSafariSelectionUsingDocumentJavaScript() async {
        var capturedScript = ""
        let reader = SelectionBrowserTextReader(appleScriptRunner: { script in
            capturedScript = script
            return .success("swift")
        })

        let result = await reader.readSelectedText(bundleIdentifier: "com.apple.Safari")

        XCTAssertEqual(result, .success("swift"))
        XCTAssertTrue(capturedScript.contains(#"tell application id "com.apple.Safari""#))
        XCTAssertTrue(capturedScript.contains(#"do JavaScript "window.getSelection().toString();" in document 1"#))
    }

    @MainActor
    func testUnsupportedBrowserReturnsUnsupportedWithoutRunningScript() async {
        var didRunScript = false
        let reader = SelectionBrowserTextReader(appleScriptRunner: { _ in
            didRunScript = true
            return .success("ignored")
        })

        let result = await reader.readSelectedText(bundleIdentifier: "com.openai.codex")

        XCTAssertEqual(result, .unsupported)
        XCTAssertFalse(didRunScript)
    }

    @MainActor
    func testEmptyBrowserSelectionReturnsEmptySelection() async {
        let reader = SelectionBrowserTextReader(appleScriptRunner: { _ in .success("  \n  ") })

        let result = await reader.readSelectedText(bundleIdentifier: "com.microsoft.edgemac")

        XCTAssertEqual(result, .emptySelection)
    }
}
