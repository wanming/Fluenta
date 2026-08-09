public struct WritingPopoverKeyboardModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = WritingPopoverKeyboardModifiers(rawValue: 1 << 0)
    public static let shift = WritingPopoverKeyboardModifiers(rawValue: 1 << 1)
    public static let option = WritingPopoverKeyboardModifiers(rawValue: 1 << 2)
    public static let control = WritingPopoverKeyboardModifiers(rawValue: 1 << 3)
}

public enum WritingPopoverKeyboardAction: Equatable, Sendable {
    case passThrough
    case consume
    case escape
    case moveHighlight(Int)
    case commitMode
    case cycleMode(Int)
    case submit
    case insertOriginal
}

public enum WritingPopoverKeyboardPolicy {
    public static func action(
        route: WritingPopoverSessionState.Route,
        keyCode: UInt16,
        modifiers: WritingPopoverKeyboardModifiers,
        isComposingText: Bool
    ) -> WritingPopoverKeyboardAction {
        let isReturnKey = keyCode == 36 || keyCode == 76

        switch route {
        case .modePicker:
            let isNavigationKey = keyCode == 48
                || keyCode == 53
                || keyCode == 125
                || keyCode == 126
                || isReturnKey

            if isComposingText, isNavigationKey {
                return .passThrough
            }

            if keyCode == 53 {
                return .escape
            }

            if isReturnKey {
                return .consume
            }

            guard modifiers.isEmpty else {
                return .passThrough
            }

            switch keyCode {
            case 126:
                return .moveHighlight(-1)
            case 125:
                return .moveHighlight(1)
            case 48:
                return .commitMode
            default:
                return .passThrough
            }

        case .editor:
            if isComposingText, isReturnKey || keyCode == 53 {
                return .passThrough
            }

            if keyCode == 53 {
                return .escape
            }

            if modifiers.contains(.command),
               !modifiers.contains(.shift),
               !modifiers.contains(.option)
            {
                if keyCode == 126 {
                    return .cycleMode(-1)
                }

                if keyCode == 125 {
                    return .cycleMode(1)
                }
            }

            guard isReturnKey else {
                return .passThrough
            }

            if modifiers.contains(.command) {
                return .insertOriginal
            }

            if !modifiers.contains(.shift), !modifiers.contains(.option) {
                return .submit
            }

            return .passThrough
        }
    }
}
