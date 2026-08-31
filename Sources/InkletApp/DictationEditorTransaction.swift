import AppKit

final class WeakObjectReference<Object: AnyObject> {
    private(set) weak var value: Object?

    init(_ value: Object) {
        self.value = value
    }

    func clear() {
        value = nil
    }
}

@MainActor
protocol DictationEditorTransacting: AnyObject {
    func replaceProvisional(with cumulativeText: String) throws
    func commitFinal(_ text: String) throws
    func restore()
}

enum DictationEditorTransactionError: Error, Equatable {
    case editorUnavailable
    case invalidOwnedRange
    case transactionFinished
}

@MainActor
final class DictationEditorTransaction: DictationEditorTransacting {
    struct Snapshot: Equatable {
        let string: String
        let selectedRange: NSRange
    }

    private struct AttributedRangeState {
        let range: NSRange
        let fragment: NSAttributedString
        let temporaryAttributeRuns: [TemporaryAttributeRun]
        let selectedRange: NSRange
    }

    private struct TemporaryAttributeRun {
        let range: NSRange
        let attributes: [NSAttributedString.Key: Any]
    }

    private let editorReference: WeakObjectReference<NSTextView>
    private weak var originalWindow: NSWindow?
    private let original: Snapshot
    private let originalRangeState: AttributedRangeState
    private var ownedRange: NSRange
    private var underlinedRange: NSRange?
    private var replacedUnderlineRuns: [TemporaryAttributeRun] = []
    private let originalIsEditable: Bool
    private let originalIsSelectable: Bool
    private let originalWasFirstResponder: Bool
    private let synchronizeProvisional: (String) -> Void
    private let commitSourceChange: (String) -> Void
    private let restoreModelSnapshot: () -> Void
    private var terminal = false

    convenience init?(
        textView: NSTextView,
        synchronizeProvisional: @escaping (String) -> Void,
        commitSourceChange: @escaping (String) -> Void,
        restoreModelSnapshot: @escaping () -> Void
    ) {
        self.init(
            textView: textView,
            editorReference: WeakObjectReference(textView),
            synchronizeProvisional: synchronizeProvisional,
            commitSourceChange: commitSourceChange,
            restoreModelSnapshot: restoreModelSnapshot
        )
    }

    init?(
        textView: NSTextView,
        editorReference: WeakObjectReference<NSTextView>,
        synchronizeProvisional: @escaping (String) -> Void,
        commitSourceChange: @escaping (String) -> Void,
        restoreModelSnapshot: @escaping () -> Void
    ) {
        let selection = textView.selectedRange()
        let stringLength = (textView.string as NSString).length
        guard editorReference.value === textView,
              Self.isValid(selection, within: stringLength),
              let textStorage = textView.textStorage
        else {
            return nil
        }

        self.editorReference = editorReference
        self.originalWindow = textView.window
        self.original = Snapshot(
            string: textView.string,
            selectedRange: selection
        )
        self.originalRangeState = AttributedRangeState(
            range: selection,
            fragment: NSAttributedString(
                attributedString: textStorage.attributedSubstring(from: selection)
            ),
            temporaryAttributeRuns: Self.temporaryAttributeRuns(
                in: selection,
                from: textView.layoutManager
            ),
            selectedRange: selection
        )
        self.ownedRange = selection
        self.originalIsEditable = textView.isEditable
        self.originalIsSelectable = textView.isSelectable
        self.originalWasFirstResponder = textView.window?.firstResponder === textView
        self.synchronizeProvisional = synchronizeProvisional
        self.commitSourceChange = commitSourceChange
        self.restoreModelSnapshot = restoreModelSnapshot

        textView.isEditable = false
        textView.isSelectable = false
    }

    func replaceProvisional(with cumulativeText: String) throws {
        try ensureActive()
        guard let textView = editorReference.value else {
            throw DictationEditorTransactionError.editorUnavailable
        }

        try replaceOwnedRange(
            in: textView,
            with: cumulativeText,
            shouldUnderline: true
        )
        synchronizeProvisional(textView.string)
    }

    func commitFinal(_ text: String) throws {
        try ensureActive()
        guard let textView = editorReference.value else {
            throw DictationEditorTransactionError.editorUnavailable
        }

        try replaceOwnedRange(in: textView, with: text, shouldUnderline: false)
        guard let textStorage = textView.textStorage else {
            throw DictationEditorTransactionError.editorUnavailable
        }
        let committed = Snapshot(
            string: textView.string,
            selectedRange: textView.selectedRange()
        )
        let committedRangeState = AttributedRangeState(
            range: ownedRange,
            fragment: NSAttributedString(
                attributedString: textStorage.attributedSubstring(from: ownedRange)
            ),
            temporaryAttributeRuns: Self.temporaryAttributeRuns(
                in: ownedRange,
                from: textView.layoutManager
            ),
            selectedRange: committed.selectedRange
        )
        terminal = true
        restoreInteraction(on: textView)
        synchronizeProvisional(committed.string)
        registerUndo(
            from: committedRangeState,
            to: originalRangeState,
            for: textView
        )
        commitSourceChange(committed.string)
    }

    func restore() {
        guard !terminal else {
            return
        }
        terminal = true

        if let textView = editorReference.value {
            removeOwnedUnderline(from: textView)
            Self.apply(
                replacing: ownedRange,
                with: originalRangeState,
                to: textView
            )
            restoreInteraction(on: textView)
            synchronizeProvisional(textView.string)
        } else {
            synchronizeProvisional(original.string)
        }

        restoreModelSnapshot()
    }

    private func ensureActive() throws {
        guard !terminal else {
            throw DictationEditorTransactionError.transactionFinished
        }
    }

    private func replaceOwnedRange(
        in textView: NSTextView,
        with replacement: String,
        shouldUnderline: Bool
    ) throws {
        let stringLength = (textView.string as NSString).length
        guard Self.isValid(ownedRange, within: stringLength),
              let textStorage = textView.textStorage
        else {
            throw DictationEditorTransactionError.invalidOwnedRange
        }

        removeOwnedUnderline(from: textView)
        Self.withAutomaticUndoDisabled(for: textView) {
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: ownedRange, with: replacement)
            textStorage.endEditing()
        }

        ownedRange.length = (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: NSMaxRange(ownedRange), length: 0))

        if shouldUnderline, ownedRange.length > 0 {
            replacedUnderlineRuns = Self.temporaryAttributeRuns(
                in: ownedRange,
                from: textView.layoutManager,
                including: [.underlineStyle]
            )
            textView.layoutManager?.addTemporaryAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                forCharacterRange: ownedRange
            )
            underlinedRange = ownedRange
        }
    }

    private func removeOwnedUnderline(from textView: NSTextView) {
        guard let underlinedRange else {
            return
        }
        if Self.isValid(
            underlinedRange,
            within: (textView.string as NSString).length
        ), let layoutManager = textView.layoutManager {
            layoutManager.removeTemporaryAttribute(
                .underlineStyle,
                forCharacterRange: underlinedRange
            )
            Self.addTemporaryAttributeRuns(
                replacedUnderlineRuns,
                in: underlinedRange,
                to: layoutManager
            )
        }
        self.underlinedRange = nil
        replacedUnderlineRuns = []
    }

    private func restoreInteraction(on textView: NSTextView) {
        textView.isEditable = originalIsEditable
        textView.isSelectable = originalIsSelectable

        guard originalWasFirstResponder,
              let originalWindow,
              textView.window === originalWindow
        else {
            return
        }
        originalWindow.makeFirstResponder(textView)
    }

    private func registerUndo(
        from current: AttributedRangeState,
        to previous: AttributedRangeState,
        for textView: NSTextView
    ) {
        guard let undoManager = textView.undoManager,
              undoManager.isUndoRegistrationEnabled
        else {
            return
        }

        let target = UndoTarget(
            editorReference: editorReference,
            undoManager: undoManager,
            synchronizeSource: synchronizeProvisional
        )
        target.register(current: current, replacement: previous)
    }

    private static func isValid(_ range: NSRange, within stringLength: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= stringLength
            && range.length <= stringLength - range.location
    }

    private static func temporaryAttributeRuns(
        in range: NSRange,
        from layoutManager: NSLayoutManager?,
        including keys: Set<NSAttributedString.Key>? = nil
    ) -> [TemporaryAttributeRun] {
        guard range.length > 0,
              let layoutManager,
              isValid(range, within: layoutManager.textStorage?.length ?? 0)
        else {
            return []
        }

        var runs: [TemporaryAttributeRun] = []
        var location = range.location
        while location < NSMaxRange(range) {
            var effectiveRange = NSRange()
            let allAttributes = layoutManager.temporaryAttributes(
                atCharacterIndex: location,
                effectiveRange: &effectiveRange
            )
            let attributes: [NSAttributedString.Key: Any]
            if let keys {
                attributes = allAttributes.filter { keys.contains($0.key) }
            } else {
                attributes = allAttributes
            }
            let intersection = NSIntersectionRange(effectiveRange, range)
            if !attributes.isEmpty, intersection.length > 0 {
                runs.append(TemporaryAttributeRun(
                    range: NSRange(
                        location: intersection.location - range.location,
                        length: intersection.length
                    ),
                    attributes: attributes
                ))
            }
            location = max(NSMaxRange(effectiveRange), location + 1)
        }
        return runs
    }

    private static func restoreTemporaryAttributeRuns(
        _ runs: [TemporaryAttributeRun],
        in range: NSRange,
        to layoutManager: NSLayoutManager
    ) {
        guard range.length > 0,
              isValid(range, within: layoutManager.textStorage?.length ?? 0)
        else {
            return
        }
        layoutManager.setTemporaryAttributes([:], forCharacterRange: range)
        addTemporaryAttributeRuns(runs, in: range, to: layoutManager)
    }

    private static func addTemporaryAttributeRuns(
        _ runs: [TemporaryAttributeRun],
        in range: NSRange,
        to layoutManager: NSLayoutManager
    ) {
        for run in runs where isValid(run.range, within: range.length) {
            layoutManager.addTemporaryAttributes(
                run.attributes,
                forCharacterRange: NSRange(
                    location: range.location + run.range.location,
                    length: run.range.length
                )
            )
        }
    }

    @discardableResult
    private static func apply(
        replacing currentRange: NSRange,
        with replacement: AttributedRangeState,
        to textView: NSTextView
    ) -> Bool {
        let stringLength = (textView.string as NSString).length
        guard isValid(currentRange, within: stringLength),
              let textStorage = textView.textStorage
        else {
            return false
        }

        withAutomaticUndoDisabled(for: textView) {
            textStorage.beginEditing()
            textStorage.replaceCharacters(
                in: currentRange,
                with: replacement.fragment
            )
            textStorage.endEditing()
            let replacementRange = NSRange(
                location: currentRange.location,
                length: replacement.fragment.length
            )
            if let layoutManager = textView.layoutManager {
                restoreTemporaryAttributeRuns(
                    replacement.temporaryAttributeRuns,
                    in: replacementRange,
                    to: layoutManager
                )
            }
            textView.setSelectedRange(replacement.selectedRange)
        }
        return true
    }

    private static func withAutomaticUndoDisabled(
        for textView: NSTextView,
        _ operation: () -> Void
    ) {
        let undoManager = textView.undoManager
        let shouldRestoreRegistration = undoManager?.isUndoRegistrationEnabled == true
        if shouldRestoreRegistration {
            undoManager?.disableUndoRegistration()
        }
        defer {
            if shouldRestoreRegistration {
                undoManager?.enableUndoRegistration()
            }
        }
        operation()
    }

    @MainActor
    private final class UndoTarget {
        private let editorReference: WeakObjectReference<NSTextView>
        private weak var undoManager: UndoManager?
        private let synchronizeSource: (String) -> Void

        init(
            editorReference: WeakObjectReference<NSTextView>,
            undoManager: UndoManager,
            synchronizeSource: @escaping (String) -> Void
        ) {
            self.editorReference = editorReference
            self.undoManager = undoManager
            self.synchronizeSource = synchronizeSource
        }

        func register(
            current: AttributedRangeState,
            replacement: AttributedRangeState
        ) {
            guard let undoManager else {
                return
            }
            let opensStandaloneGroup = undoManager.groupingLevel == 0
            if opensStandaloneGroup {
                undoManager.beginUndoGrouping()
            }
            undoManager.registerUndo(withTarget: self) { [self] _ in
                replace(current: current, with: replacement)
            }
            if opensStandaloneGroup {
                undoManager.endUndoGrouping()
            }
        }

        private func replace(
            current: AttributedRangeState,
            with replacement: AttributedRangeState
        ) {
            guard let textView = editorReference.value,
                  let undoManager
            else {
                return
            }

            guard DictationEditorTransaction.apply(
                replacing: current.range,
                with: replacement,
                to: textView
            ) else {
                return
            }
            synchronizeSource(textView.string)
            undoManager.registerUndo(withTarget: self) { [self] _ in
                replace(current: replacement, with: current)
            }
        }
    }
}
