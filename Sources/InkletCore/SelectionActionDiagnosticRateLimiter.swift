import Foundation

public enum SelectionActionDiagnosticRateLimitDecision: Equatable, Sendable {
    case log(suppressedCount: Int)
    case suppress
}

public struct SelectionActionDiagnosticRateLimiter: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var lastLogTime: TimeInterval
        var suppressedCount: Int
    }

    private let interval: TimeInterval
    private var entries: [String: Entry] = [:]

    public init(interval: TimeInterval = 1) {
        self.interval = interval
    }

    public mutating func record(
        signature: String,
        at time: TimeInterval
    ) -> SelectionActionDiagnosticRateLimitDecision {
        if var entry = entries[signature] {
            let elapsed = time - entry.lastLogTime
            if elapsed >= 0, elapsed < interval {
                entry.suppressedCount += 1
                entries[signature] = entry
                return .suppress
            }

            entries[signature] = Entry(lastLogTime: time, suppressedCount: 0)
            return .log(suppressedCount: entry.suppressedCount)
        }

        entries[signature] = Entry(lastLogTime: time, suppressedCount: 0)
        return .log(suppressedCount: 0)
    }

    public mutating func reset() {
        entries.removeAll(keepingCapacity: true)
    }
}
