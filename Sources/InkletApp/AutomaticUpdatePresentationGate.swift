import Foundation

@MainActor
final class AutomaticUpdatePresentationGate {
    typealias Eligibility = @MainActor () -> Bool
    typealias Presentation = @MainActor () -> Void
    typealias DeferredAction = @MainActor () -> Void
    typealias Deferral = @MainActor (@escaping DeferredAction) -> (@MainActor () -> Void)

    private struct ScheduledTask {
        let id: UUID
        let cancel: @MainActor () -> Void
    }

    private let canPresent: Eligibility
    private let present: Presentation
    private let deferAction: Deferral
    private var generation: UInt64 = 0
    private var scheduledTask: ScheduledTask?

    init(
        canPresent: @escaping Eligibility,
        present: @escaping Presentation,
        deferAction: @escaping Deferral = { action in
            let task = Task { @MainActor in
                await Task.yield()
                action()
            }
            return { task.cancel() }
        }
    ) {
        self.canPresent = canPresent
        self.present = present
        self.deferAction = deferAction
    }

    func schedule() {
        guard scheduledTask == nil else { return }

        let id = UUID()
        let generation = generation
        scheduledTask = ScheduledTask(id: id, cancel: {})
        let cancel = deferAction { [weak self] in
            guard let self,
                  self.generation == generation,
                  self.scheduledTask?.id == id
            else {
                return
            }

            let isEligible = self.canPresent()
            guard self.generation == generation,
                  self.scheduledTask?.id == id
            else {
                return
            }

            self.scheduledTask = nil
            guard isEligible else { return }
            self.present()
        }
        guard scheduledTask?.id == id else {
            cancel()
            return
        }
        scheduledTask = ScheduledTask(id: id, cancel: cancel)
    }

    func cancel() {
        generation &+= 1
        scheduledTask?.cancel()
        scheduledTask = nil
    }
}
