import AppKit

@MainActor
public struct SelectionSourceValidator {
    public typealias ProcessRunningChecker = @MainActor @Sendable (pid_t) -> Bool
    public typealias FrontmostProcessIdentifierProvider = @MainActor @Sendable () -> pid_t?

    private let isProcessRunning: ProcessRunningChecker
    private let frontmostProcessIdentifier: FrontmostProcessIdentifierProvider

    public init(
        isProcessRunning: @escaping ProcessRunningChecker = {
            NSRunningApplication(processIdentifier: $0)?.isTerminated == false
        },
        frontmostProcessIdentifier: @escaping FrontmostProcessIdentifierProvider = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    ) {
        self.isProcessRunning = isProcessRunning
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
    }

    public func isCurrent(_ processIdentifier: pid_t) -> Bool {
        isProcessRunning(processIdentifier)
            && frontmostProcessIdentifier() == processIdentifier
    }
}
