import XCTest
@testable import InkletCore

final class SelectionSourceValidatorTests: XCTestCase {
    @MainActor
    func testRequiresRunningFrontmostProcess() {
        let state = SelectionSourceState()
        let validator = SelectionSourceValidator(
            isProcessRunning: { _ in state.running },
            frontmostProcessIdentifier: { state.frontmostProcessIdentifier }
        )

        XCTAssertTrue(validator.isCurrent(42))
        state.frontmostProcessIdentifier = 99
        XCTAssertFalse(validator.isCurrent(42))
        state.frontmostProcessIdentifier = 42
        state.running = false
        XCTAssertFalse(validator.isCurrent(42))
    }
}

@MainActor
private final class SelectionSourceState {
    var running = true
    var frontmostProcessIdentifier: pid_t? = 42
}
