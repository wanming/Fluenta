import XCTest
@testable import InkletCore

final class OnboardingPolicyTests: XCTestCase {
    func testNeedsProviderSetupWhenProviderAPIKeyIsMissing() {
        XCTAssertTrue(OnboardingPolicy.needsProviderSetup(providerAPIKey: "  "))
        XCTAssertFalse(OnboardingPolicy.needsProviderSetup(providerAPIKey: "sk-text"))
    }

    func testShowsProviderSetupAfterReturningFromPermissionSettingsWhenAPIKeyIsMissing() {
        XCTAssertTrue(
            OnboardingPolicy.shouldShowProviderSetupAfterReturningFromPermissionSettings(providerAPIKey: "  ")
        )
        XCTAssertFalse(
            OnboardingPolicy.shouldShowProviderSetupAfterReturningFromPermissionSettings(providerAPIKey: "sk-text")
        )
    }

    func testShowsVoiceShortcutHintOnlyWhenVoiceInputIsConfiguredAndEnabled() {
        XCTAssertTrue(OnboardingPolicy.shouldShowVoiceShortcutHint(
            openAIAPIKey: "sk-openai",
            shortcut: .rightOption
        ))
        XCTAssertFalse(OnboardingPolicy.shouldShowVoiceShortcutHint(
            openAIAPIKey: "  ",
            shortcut: .rightOption
        ))
        XCTAssertFalse(OnboardingPolicy.shouldShowVoiceShortcutHint(
            openAIAPIKey: "sk-openai",
            shortcut: .disabled
        ))
    }

    func testOpensPopoverWhenClosingSettingsAfterCompletingOnboarding() {
        XCTAssertTrue(OnboardingPolicy.shouldOpenPopoverAfterClosingSettings(
            didOpenAccessibilitySettings: true,
            isAccessibilityTrusted: true,
            providerAPIKey: "sk-text",
            didCompleteOnboarding: false
        ))
        XCTAssertFalse(OnboardingPolicy.shouldOpenPopoverAfterClosingSettings(
            didOpenAccessibilitySettings: false,
            isAccessibilityTrusted: true,
            providerAPIKey: "sk-text",
            didCompleteOnboarding: false
        ))
        XCTAssertFalse(OnboardingPolicy.shouldOpenPopoverAfterClosingSettings(
            didOpenAccessibilitySettings: true,
            isAccessibilityTrusted: true,
            providerAPIKey: "",
            didCompleteOnboarding: false
        ))
        XCTAssertFalse(OnboardingPolicy.shouldOpenPopoverAfterClosingSettings(
            didOpenAccessibilitySettings: true,
            isAccessibilityTrusted: true,
            providerAPIKey: "sk-text",
            didCompleteOnboarding: true
        ))
    }
}
