import Foundation

@MainActor
public final class SelectionReadPipeline {
    public typealias SourceValidator = @MainActor @Sendable (pid_t) -> Bool
    public typealias AccessibilityReader = @MainActor @Sendable (
        pid_t,
        SelectionPoint?
    ) -> SelectedTextReadResult
    public typealias ClipboardReader = @MainActor @Sendable (
        pid_t,
        SelectionForceSelectionMode
    ) async -> SelectedTextReadResult

    private let sourceValidator: SourceValidator
    private let accessibilityReader: AccessibilityReader
    private let clipboardReader: ClipboardReader

    public init(
        sourceValidator: @escaping SourceValidator,
        accessibilityReader: @escaping AccessibilityReader,
        clipboardReader: @escaping ClipboardReader
    ) {
        self.sourceValidator = sourceValidator
        self.accessibilityReader = accessibilityReader
        self.clipboardReader = clipboardReader
    }

    public func readSelectedText(
        sourceProcessIdentifier: pid_t,
        mouseLocation: SelectionPoint?,
        forceSelectionMode: SelectionForceSelectionMode
    ) async -> SelectedTextReadResult {
        guard sourceValidator(sourceProcessIdentifier) else {
            return .emptySelection
        }

        let accessibilityResult = accessibilityReader(sourceProcessIdentifier, mouseLocation)
        switch accessibilityResult {
        case .success:
            return sourceValidator(sourceProcessIdentifier) ? accessibilityResult : .emptySelection
        case .permissionDenied:
            return accessibilityResult
        case .emptySelection, .unsupported, .missingFocusedElement, .failed:
            break
        }

        guard forceSelectionMode != .disabled else {
            return accessibilityResult
        }

        let clipboardResult = await clipboardReader(sourceProcessIdentifier, forceSelectionMode)
        guard sourceValidator(sourceProcessIdentifier) else {
            return .emptySelection
        }
        return clipboardResult == .unsupported ? accessibilityResult : clipboardResult
    }
}
