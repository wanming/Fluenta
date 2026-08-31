import XCTest
@testable import InkletCore

final class RealtimeTranscriptionTypesTests: XCTestCase {
    func testServerErrorDescriptionDoesNotExposeProviderDetails() {
        let description = RealtimeTranscriptionError.server(
            code: "raw-code", message: "sensitive raw detail"
        ).errorDescription

        XCTAssertEqual(description, "The transcription server returned an error.")
        XCTAssertFalse(description?.contains("raw-code") == true)
        XCTAssertFalse(description?.contains("sensitive raw detail") == true)
    }
}
