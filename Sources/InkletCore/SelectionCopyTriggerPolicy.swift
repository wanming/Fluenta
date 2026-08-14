import Foundation

public enum SelectionCopyKeyDownDecision: Equatable, Sendable {
    case ignoredRepeat
    case ignoredGenerated
    case armed
    case awaitingKeyUp
    case triggered(initialPasteboardChangeCount: Int)
}

public struct SelectionCopyTriggerPolicy: Equatable, Sendable {
    private let doubleCopyInterval: TimeInterval
    private var firstCopyTime: TimeInterval?
    private var firstPasteboardChangeCount: Int?
    private var didReleaseCopyKey = false

    public init(doubleCopyInterval: TimeInterval = 0.8) {
        self.doubleCopyInterval = doubleCopyInterval
    }

    public mutating func recordKeyDown(
        at time: TimeInterval,
        pasteboardChangeCount: Int,
        isRepeat: Bool,
        isInkletGenerated: Bool
    ) -> SelectionCopyKeyDownDecision {
        guard !isInkletGenerated else {
            return .ignoredGenerated
        }
        guard !isRepeat else {
            return .ignoredRepeat
        }

        guard let firstCopyTime, let firstPasteboardChangeCount else {
            arm(at: time, pasteboardChangeCount: pasteboardChangeCount)
            return .armed
        }

        let elapsed = time - firstCopyTime
        guard elapsed >= 0, elapsed <= doubleCopyInterval else {
            arm(at: time, pasteboardChangeCount: pasteboardChangeCount)
            return .armed
        }

        guard didReleaseCopyKey else {
            return .awaitingKeyUp
        }

        reset()
        return .triggered(initialPasteboardChangeCount: firstPasteboardChangeCount)
    }

    public mutating func recordKeyUp(isInkletGenerated: Bool) {
        guard !isInkletGenerated, firstCopyTime != nil else {
            return
        }
        didReleaseCopyKey = true
    }

    public mutating func reset() {
        firstCopyTime = nil
        firstPasteboardChangeCount = nil
        didReleaseCopyKey = false
    }

    public static func validatedClipboardText(
        initialChangeCount: Int,
        currentChangeCount: Int,
        text: String?
    ) -> String? {
        guard currentChangeCount != initialChangeCount else {
            return nil
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public mutating func recordCopy(at time: TimeInterval) -> Bool {
        let decision = recordKeyDown(
            at: time,
            pasteboardChangeCount: 0,
            isRepeat: false,
            isInkletGenerated: false
        )
        recordKeyUp(isInkletGenerated: false)
        if case .triggered = decision {
            return true
        }
        return false
    }

    private mutating func arm(at time: TimeInterval, pasteboardChangeCount: Int) {
        firstCopyTime = time
        firstPasteboardChangeCount = pasteboardChangeCount
        didReleaseCopyKey = false
    }
}
