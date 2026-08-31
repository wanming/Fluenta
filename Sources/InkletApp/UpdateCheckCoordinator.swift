import Foundation
import InkletCore

enum UpdateCheckSchedulePolicy {
    static let interval: TimeInterval = 24 * 60 * 60

    static func delay(
        lastAttempt: Date?,
        now: Date,
        interval: TimeInterval = UpdateCheckSchedulePolicy.interval
    ) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return 0 }
        guard let lastAttempt else { return 0 }

        let elapsed = now.timeIntervalSince(lastAttempt)
        guard elapsed.isFinite else { return interval }
        guard elapsed >= 0 else { return interval }
        guard elapsed < interval else { return 0 }
        return min(max(interval - elapsed, 0), interval)
    }
}

@MainActor
protocol UpdateCheckOneShotScheduling: AnyObject {
    typealias Action = @MainActor @Sendable () -> Void

    func schedule(after delay: TimeInterval, action: @escaping Action)
    func cancel()
}

@MainActor
final class FoundationUpdateCheckOneShotScheduler: UpdateCheckOneShotScheduling {
    private var timer: Timer?

    func schedule(after delay: TimeInterval, action: @escaping Action) {
        cancel()
        let timer = Timer(timeInterval: max(delay, 0), repeats: false) { _ in
            Task { @MainActor in
                action()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
protocol UpdateCheckPresenting: AnyObject {
    func presentUpdate(_ release: InkletRelease, currentVersion: String)
    func presentUpToDate(currentVersion: String)
    func presentFailure(retry: @escaping @MainActor () -> Void)
}

@MainActor
final class UpdateCheckCoordinator {
    typealias Check = @MainActor @Sendable () async throws -> AppUpdateCheckResult

    private struct Intent: OptionSet {
        let rawValue: UInt8

        static let manual = Intent(rawValue: 1 << 0)
        static let automatic = Intent(rawValue: 1 << 1)
    }

    private struct ActiveRequest {
        let id: UUID
        let generation: UInt64
        var intents: Intent
        let task: Task<Void, Never>
    }

    private struct PendingAutomaticUpdate {
        let id = UUID()
        let release: InkletRelease
    }

    private enum Outcome {
        case success(AppUpdateCheckResult)
        case failure
    }

    private(set) var isChecking = false
    var onCheckingStateChange: (@MainActor (Bool) -> Void)?

    private let automaticChecksEnabled: Bool
    private let currentVersion: String
    private let userDefaults: UserDefaults
    private let scheduler: any UpdateCheckOneShotScheduling
    private let presenter: any UpdateCheckPresenting
    private let now: @MainActor () -> Date
    private let canPresentAutomatically: @MainActor () -> Bool
    private let check: Check

    private var isStarted = false
    private var lifecycleGeneration: UInt64 = 0
    private var activeRequest: ActiveRequest?
    private var pendingAutomaticUpdate: PendingAutomaticUpdate?

    init(
        automaticChecksEnabled: Bool,
        currentVersion: String,
        userDefaults: UserDefaults = .standard,
        scheduler: any UpdateCheckOneShotScheduling,
        presenter: any UpdateCheckPresenting,
        now: @escaping @MainActor () -> Date = Date.init,
        canPresentAutomatically: @escaping @MainActor () -> Bool,
        check: @escaping Check
    ) {
        self.automaticChecksEnabled = automaticChecksEnabled
        self.currentVersion = currentVersion
        self.userDefaults = userDefaults
        self.scheduler = scheduler
        self.presenter = presenter
        self.now = now
        self.canPresentAutomatically = canPresentAutomatically
        self.check = check
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lifecycleGeneration &+= 1
        guard automaticChecksEnabled else { return }

        let capturedNow = now()
        let lastAttempt = userDefaults.object(
            forKey: InkletPreferenceKeys.lastAutomaticUpdateCheckDate
        ) as? Date
        let delay = UpdateCheckSchedulePolicy.delay(lastAttempt: lastAttempt, now: capturedNow)
        if delay == 0 {
            beginAutomaticIntent(at: capturedNow)
        } else {
            scheduleAutomaticIntent(after: delay)
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        lifecycleGeneration &+= 1
        scheduler.cancel()
        pendingAutomaticUpdate = nil

        guard let activeRequest else { return }
        self.activeRequest = nil
        activeRequest.task.cancel()
        setChecking(false)
    }

    func checkManually() {
        guard isStarted else { return }
        joinOrStartRequest(with: .manual)
    }

    func presentPendingAutomaticUpdateIfPossible() {
        guard isStarted,
              activeRequest == nil,
              let pendingUpdate = pendingAutomaticUpdate
        else {
            return
        }

        let generation = lifecycleGeneration
        let canPresent = canPresentAutomatically()
        guard canPresent,
              isStarted,
              lifecycleGeneration == generation,
              activeRequest == nil,
              pendingAutomaticUpdate?.id == pendingUpdate.id
        else {
            return
        }

        pendingAutomaticUpdate = nil
        presenter.presentUpdate(pendingUpdate.release, currentVersion: currentVersion)
    }

    private func scheduleAutomaticIntent(after delay: TimeInterval) {
        let generation = lifecycleGeneration
        scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.beginAutomaticIntent(at: self.now())
        }
    }

    private func beginAutomaticIntent(at attemptDate: Date) {
        guard isStarted, automaticChecksEnabled else { return }

        userDefaults.set(
            attemptDate,
            forKey: InkletPreferenceKeys.lastAutomaticUpdateCheckDate
        )
        scheduleAutomaticIntent(after: UpdateCheckSchedulePolicy.interval)
        joinOrStartRequest(with: .automatic)
    }

    private func joinOrStartRequest(with intent: Intent) {
        if activeRequest != nil {
            activeRequest?.intents.formUnion(intent)
            return
        }

        let id = UUID()
        let generation = lifecycleGeneration
        let task = Task { @MainActor [weak self, check] in
            let outcome: Outcome
            do {
                outcome = .success(try await check())
            } catch {
                outcome = .failure
            }
            self?.completeRequest(id: id, generation: generation, outcome: outcome)
        }
        activeRequest = ActiveRequest(
            id: id,
            generation: generation,
            intents: intent,
            task: task
        )
        setChecking(true)
    }

    private func completeRequest(id: UUID, generation: UInt64, outcome: Outcome) {
        guard let request = activeRequest,
              request.id == id,
              request.generation == generation,
              lifecycleGeneration == generation
        else {
            return
        }
        activeRequest = nil
        setChecking(false)
        guard isStarted,
              lifecycleGeneration == generation,
              activeRequest == nil
        else { return }

        if request.intents.contains(.manual) {
            presentManualOutcome(outcome, generation: generation)
        } else {
            presentAutomaticOutcome(outcome, generation: generation)
        }
    }

    private func presentManualOutcome(_ outcome: Outcome, generation: UInt64) {
        switch outcome {
        case let .success(.updateAvailable(release)):
            pendingAutomaticUpdate = nil
            presenter.presentUpdate(release, currentVersion: currentVersion)
        case .success(.upToDate):
            pendingAutomaticUpdate = nil
            presenter.presentUpToDate(currentVersion: currentVersion)
        case .failure:
            presenter.presentFailure { [weak self] in
                guard let self,
                      self.isStarted,
                      self.lifecycleGeneration == generation
                else {
                    return
                }
                self.checkManually()
            }
        }
    }

    private func presentAutomaticOutcome(_ outcome: Outcome, generation: UInt64) {
        switch outcome {
        case let .success(.updateAvailable(release)):
            let pendingUpdateID = pendingAutomaticUpdate?.id
            let canPresent = canPresentAutomatically()
            guard isStarted,
                  lifecycleGeneration == generation,
                  activeRequest == nil,
                  pendingAutomaticUpdate?.id == pendingUpdateID
            else {
                return
            }

            if canPresent {
                pendingAutomaticUpdate = nil
                presenter.presentUpdate(release, currentVersion: currentVersion)
            } else {
                pendingAutomaticUpdate = PendingAutomaticUpdate(release: release)
            }
        case .success(.upToDate):
            pendingAutomaticUpdate = nil
        case .failure:
            break
        }
    }

    private func setChecking(_ isChecking: Bool) {
        guard self.isChecking != isChecking else { return }
        self.isChecking = isChecking
        onCheckingStateChange?(isChecking)
    }
}
