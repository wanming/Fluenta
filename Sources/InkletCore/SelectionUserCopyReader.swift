import AppKit
import Foundation

@MainActor
public final class SelectionUserCopyReader {
    public typealias SourceProcessValidator = @MainActor @Sendable (pid_t) -> Bool
    public typealias DelayProvider = @MainActor @Sendable (UInt64) async -> Void
    public typealias PasteboardStringReader = @MainActor @Sendable (NSPasteboard) -> String?

    private let pasteboard: NSPasteboard
    private let pollIntervalNanoseconds: UInt64
    private let pollTimeoutNanoseconds: UInt64
    private let sourceProcessValidator: SourceProcessValidator
    private let delayProvider: DelayProvider
    private let pasteboardStringReader: PasteboardStringReader

    public init(
        pasteboard: NSPasteboard = .general,
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        pollTimeoutNanoseconds: UInt64 = 400_000_000,
        sourceProcessValidator: @escaping SourceProcessValidator,
        delayProvider: @escaping DelayProvider = { try? await Task.sleep(nanoseconds: $0) },
        pasteboardStringReader: @escaping PasteboardStringReader = { $0.string(forType: .string) }
    ) {
        self.pasteboard = pasteboard
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.pollTimeoutNanoseconds = pollTimeoutNanoseconds
        self.sourceProcessValidator = sourceProcessValidator
        self.delayProvider = delayProvider
        self.pasteboardStringReader = pasteboardStringReader
    }

    public func readCopiedText(
        sourceProcessIdentifier: pid_t,
        after initialChangeCount: Int
    ) async -> SelectedTextReadResult {
        var elapsedNanoseconds: UInt64 = 0
        let effectiveIntervalNanoseconds = max(pollIntervalNanoseconds, 1)

        while true {
            guard !Task.isCancelled else {
                return .emptySelection
            }

            let candidateChangeCount = pasteboard.changeCount
            if candidateChangeCount != initialChangeCount {
                return readStableCandidate(
                    sourceProcessIdentifier: sourceProcessIdentifier,
                    changeCount: candidateChangeCount
                )
            }

            guard elapsedNanoseconds < pollTimeoutNanoseconds else {
                return .emptySelection
            }

            let remainingNanoseconds = pollTimeoutNanoseconds - elapsedNanoseconds
            let delayNanoseconds = min(effectiveIntervalNanoseconds, remainingNanoseconds)
            await delayProvider(delayNanoseconds)
            guard !Task.isCancelled else {
                return .emptySelection
            }
            elapsedNanoseconds += delayNanoseconds
        }
    }

    private func readStableCandidate(
        sourceProcessIdentifier: pid_t,
        changeCount: Int
    ) -> SelectedTextReadResult {
        guard sourceProcessValidator(sourceProcessIdentifier),
              !Task.isCancelled
        else {
            return .emptySelection
        }

        let text = pasteboardStringReader(pasteboard)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard pasteboard.changeCount == changeCount,
              !Task.isCancelled,
              sourceProcessValidator(sourceProcessIdentifier),
              pasteboard.changeCount == changeCount,
              !text.isEmpty,
              pasteboard.changeCount == changeCount
        else {
            return .emptySelection
        }

        return .success(text)
    }
}
