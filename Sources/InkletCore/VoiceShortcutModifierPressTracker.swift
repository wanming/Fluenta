import Foundation

public enum VoiceShortcutModifierTransition: Equatable, Sendable {
    case began
    case ended
    case ignored
}

public struct VoiceShortcutModifierPressTracker: Equatable, Sendable {
    private var activeKeyCode: UInt16?
    private var ignoredReleaseKeyCode: UInt16?

    public init() {}

    public mutating func transition(
        keyCode: UInt16,
        expectedKeyCode: UInt16,
        isConfiguredModifierDown: Bool
    ) -> VoiceShortcutModifierTransition {
        guard keyCode == expectedKeyCode else {
            return .ignored
        }

        if ignoredReleaseKeyCode == expectedKeyCode {
            ignoredReleaseKeyCode = nil
            return .ignored
        }

        if activeKeyCode == expectedKeyCode {
            activeKeyCode = nil
            return .ended
        }

        guard isConfiguredModifierDown else {
            return .ignored
        }

        activeKeyCode = expectedKeyCode
        return .began
    }

    public mutating func reset() {
        if let activeKeyCode {
            ignoredReleaseKeyCode = activeKeyCode
        } else {
            ignoredReleaseKeyCode = nil
        }
        activeKeyCode = nil
    }

    public mutating func resetForLifecycleBoundary() {
        activeKeyCode = nil
        ignoredReleaseKeyCode = nil
    }
}
