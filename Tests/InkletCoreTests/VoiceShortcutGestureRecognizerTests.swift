import XCTest
@testable import InkletCore

final class VoiceShortcutGestureRecognizerTests: XCTestCase {
    func testShortPressDoesNothing() {
        var subject = VoiceShortcutGestureRecognizer()

        XCTAssertEqual(subject.pressBegan(), [])
        XCTAssertEqual(subject.pressEnded(), [])
    }

    func testHoldStartsAndReleaseStopsExactlyOnce() {
        var subject = VoiceShortcutGestureRecognizer()

        _ = subject.pressBegan()
        XCTAssertEqual(subject.holdDelayElapsed(), [.start])
        XCTAssertEqual(subject.holdDelayElapsed(), [])
        XCTAssertEqual(subject.pressEnded(), [.stop])
        XCTAssertEqual(subject.pressEnded(), [])
    }

    func testInterruptedCandidateCannotStart() {
        var subject = VoiceShortcutGestureRecognizer()

        _ = subject.pressBegan()
        subject.interrupt()

        XCTAssertEqual(subject.holdDelayElapsed(), [])
        XCTAssertEqual(subject.pressEnded(), [])
    }
}
