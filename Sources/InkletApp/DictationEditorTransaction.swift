import AppKit

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

    private weak var textView: NSTextView?
    private let editorReference: EditorReference
    private weak var originalWindow: NSWindow?
    private let original: Snapshot
    private var ownedRange: NSRange
    private var underlinedRange: NSRange?
    private let originalIsEditable: Bool
    private let originalIsSelectable: Bool
    private let originalWasFirstResponder: Bool
    private let synchronizeProvisional: (String) -> Void
    private let commitSourceChange: (String) -> Void
    private let restoreModelSnapshot: () -> Void
    private var terminal = false

    init?(
        textView: NSTextView,
        synchronizeProvisional: @escaping (String) -> Void,
        commitSourceChange: @escaping (String) -> Void,
        restoreModelSnapshot: @escaping () -> Void
    ) {
        let selection = textView.selectedRange()
        let stringLength = (textView.string as NSString).length
        guard Self.isValid(selection, within: stringLength) else {
            return nil
        }

        let editorReference = EditorReference(textView)
        self.textView = textView
        self.editorReference = editorReference
        self.originalWindow = textView.window
        self.original = Snapshot(
            string: textView.string,
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
        guard let textView else {
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
        guard let textView else {
            throw DictationEditorTransactionError.editorUnavailable
        }

        try replaceOwnedRange(in: textView, with: text, shouldUnderline: false)
        let committed = Snapshot(
            string: textView.string,
            selectedRange: textView.selectedRange()
        )
        terminal = true
        restoreInteraction(on: textView)
        synchronizeProvisional(committed.string)
        registerUndo(from: committed, to: original, for: textView)
        commitSourceChange(committed.string)
    }

    func restore() {
        guard !terminal else {
            return
        }
        terminal = true

        if let textView {
            removeOwnedUnderline(from: textView)
            Self.apply(original, to: textView)
            restoreInteraction(on: textView)
        }

        synchronizeProvisional(original.string)
        restoreModelSnapshot()
    }

    #if DEBUG
    /// AppKit retains standalone text-view fixtures, so tests invalidate the
    /// shared weak reference directly to exercise the detached-editor path.
    func invalidateEditorReferenceForTesting() {
        textView = nil
        editorReference.invalidate()
    }
    #endif

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
        guard Self.isValid(ownedRange, within: stringLength) else {
            throw DictationEditorTransactionError.invalidOwnedRange
        }

        removeOwnedUnderline(from: textView)
        Self.withAutomaticUndoDisabled(for: textView) {
            textView.textStorage?.beginEditing()
            textView.textStorage?.replaceCharacters(in: ownedRange, with: replacement)
            textView.textStorage?.endEditing()
        }

        ownedRange.length = (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: NSMaxRange(ownedRange), length: 0))

        if shouldUnderline, ownedRange.length > 0 {
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
        textView.layoutManager?.removeTemporaryAttribute(
            .underlineStyle,
            forCharacterRange: underlinedRange
        )
        self.underlinedRange = nil
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
        from current: Snapshot,
        to previous: Snapshot,
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

    private static func apply(_ snapshot: Snapshot, to textView: NSTextView) {
        withAutomaticUndoDisabled(for: textView) {
            let fullRange = NSRange(
                location: 0,
                length: (textView.string as NSString).length
            )
            textView.textStorage?.beginEditing()
            textView.textStorage?.replaceCharacters(
                in: fullRange,
                with: snapshot.string
            )
            textView.textStorage?.endEditing()
            textView.setSelectedRange(snapshot.selectedRange)
        }
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
    private final class EditorReference {
        private(set) weak var textView: NSTextView?

        init(_ textView: NSTextView) {
            self.textView = textView
        }

        #if DEBUG
        func invalidate() {
            textView = nil
        }
        #endif
    }

    @MainActor
    private final class UndoTarget {
        private let editorReference: EditorReference
        private weak var undoManager: UndoManager?
        private let synchronizeSource: (String) -> Void

        init(
            editorReference: EditorReference,
            undoManager: UndoManager,
            synchronizeSource: @escaping (String) -> Void
        ) {
            self.editorReference = editorReference
            self.undoManager = undoManager
            self.synchronizeSource = synchronizeSource
        }

        func register(current: Snapshot, replacement: Snapshot) {
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

        private func replace(current: Snapshot, with replacement: Snapshot) {
            guard let textView = editorReference.textView,
                  let undoManager
            else {
                return
            }

            DictationEditorTransaction.apply(replacement, to: textView)
            synchronizeSource(replacement.string)
            undoManager.registerUndo(withTarget: self) { [self] _ in
                replace(current: replacement, with: current)
            }
        }
    }
}
