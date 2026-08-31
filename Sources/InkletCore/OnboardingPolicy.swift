import Foundation

public enum OnboardingPolicy {
    public static func shouldShowVoiceShortcutHint(
        openAIAPIKey: String?,
        shortcut: VoiceInputConfig.Shortcut
    ) -> Bool {
        openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && shortcut != .disabled
    }

    public static func needsProviderSetup(providerAPIKey: String?) -> Bool {
        providerAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    public static func shouldShowProviderSetupAfterReturningFromPermissionSettings(
        providerAPIKey: String?
    ) -> Bool {
        needsProviderSetup(providerAPIKey: providerAPIKey)
    }

    public static func shouldOpenPopoverAfterClosingSettings(
        didOpenAccessibilitySettings: Bool,
        isAccessibilityTrusted: Bool,
        providerAPIKey: String?,
        didCompleteOnboarding: Bool
    ) -> Bool {
        didOpenAccessibilitySettings
            && isAccessibilityTrusted
            && !needsProviderSetup(providerAPIKey: providerAPIKey)
            && !didCompleteOnboarding
    }

}
