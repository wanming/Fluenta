import Foundation

public enum VoiceShortcutGestureAction: Equatable, Sendable {
    case start
    case stop
}

public struct VoiceShortcutGestureRecognizer: Equatable, Sendable {
    private var isPressed = false
    private var isInterrupted = false
    private var didStart = false

    public init() {}

    public mutating func pressBegan() -> [VoiceShortcutGestureAction] {
        guard !isPressed else { return [] }
        isPressed = true
        isInterrupted = false
        didStart = false
        return []
    }

    public mutating func holdDelayElapsed() -> [VoiceShortcutGestureAction] {
        guard isPressed, !isInterrupted, !didStart else { return [] }
        didStart = true
        return [.start]
    }

    public mutating func pressEnded() -> [VoiceShortcutGestureAction] {
        defer {
            isPressed = false
            isInterrupted = false
            didStart = false
        }
        guard isPressed, !isInterrupted, didStart else { return [] }
        return [.stop]
    }

    public mutating func interrupt() {
        guard isPressed, !didStart else { return }
        isInterrupted = true
    }

    public mutating func reset() {
        self = VoiceShortcutGestureRecognizer()
    }
}
