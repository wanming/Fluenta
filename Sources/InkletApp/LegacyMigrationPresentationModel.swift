import Combine
import InkletCore

@MainActor
final class LegacyMigrationPresentationModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case needsImport
        case selecting
        case importing
        case failed
        case relaunching
        case relaunchFailed
    }

    enum FailureReason: Equatable {
        case invalidSelection
        case importFailed
        case partialFailure
    }

    @Published private(set) var phase: Phase
    @Published private(set) var outcome: LegacySandboxMigrationOutcome
    @Published private(set) var workflowsAreIdle = true
    @Published private(set) var failureReason: FailureReason?
    private var selectionReturnPhase: Phase

    init(outcome: LegacySandboxMigrationOutcome) {
        let initialPhase: Phase = outcome.hasIncompleteComponents ? .needsImport : .hidden
        self.outcome = outcome
        self.phase = initialPhase
        self.failureReason = nil
        self.selectionReturnPhase = initialPhase
    }

    var isSettingsReadOnly: Bool {
        phase == .importing || phase == .relaunching || phase == .relaunchFailed
    }

    var canRequestImport: Bool {
        phase == .needsImport || phase == .failed
    }

    var canStartImport: Bool {
        canRequestImport && workflowsAreIdle
    }

    func update(with outcome: LegacySandboxMigrationOutcome) {
        self.outcome = outcome
        phase = outcome.hasIncompleteComponents ? .failed : .hidden
        failureReason = outcome.hasIncompleteComponents ? .partialFailure : nil
        selectionReturnPhase = phase
    }

    func setWorkflowsIdle(_ isIdle: Bool) {
        workflowsAreIdle = isIdle
    }

    func beginSelecting() {
        guard canStartImport else { return }
        selectionReturnPhase = phase
        phase = .selecting
    }

    func cancelSelecting() {
        guard phase == .selecting else { return }
        phase = selectionReturnPhase
    }

    func failImport() {
        failureReason = .importFailed
        phase = .failed
    }

    func failInvalidSelection() {
        failureReason = .invalidSelection
        phase = .failed
    }

    func beginImporting() {
        failureReason = nil
        phase = .importing
    }

    func beginRelaunching(with outcome: LegacySandboxMigrationOutcome) {
        self.outcome = outcome
        phase = .relaunching
    }

    func markRelaunchFailed() {
        phase = .relaunchFailed
    }
}
