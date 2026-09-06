import Foundation

final class SelectionInteractionTracker: @unchecked Sendable {
    enum Kind: Hashable, Sendable {
        case mouse
        case keyboard
        case copy
    }

    enum Transition: Equatable, Sendable {
        case unchanged
        case becameActive
        case becameIdle
    }

    private let lock = NSLock()
    private var pressedKinds: Set<Kind> = []
    private var pendingHandoffCounts: [Kind: Int] = [:]

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActiveLocked
    }

    @discardableResult
    func begin(_ kind: Kind) -> Transition {
        update {
            pressedKinds.insert(kind)
        }
    }

    @discardableResult
    func release(_ kind: Kind) -> Transition {
        update {
            pressedKinds.remove(kind)
        }
    }

    @discardableResult
    func enqueueHandoff(for kind: Kind) -> Transition {
        update {
            pendingHandoffCounts[kind, default: 0] += 1
        }
    }

    @discardableResult
    func completeHandoff(for kind: Kind) -> Transition {
        update {
            guard let count = pendingHandoffCounts[kind], count > 0 else {
                return
            }
            if count == 1 {
                pendingHandoffCounts.removeValue(forKey: kind)
            } else {
                pendingHandoffCounts[kind] = count - 1
            }
        }
    }

    @discardableResult
    func reset() -> Transition {
        update {
            pressedKinds.removeAll()
            pendingHandoffCounts.removeAll()
        }
    }

    private var isActiveLocked: Bool {
        !pressedKinds.isEmpty || !pendingHandoffCounts.isEmpty
    }

    private func update(_ mutation: () -> Void) -> Transition {
        lock.lock()
        defer { lock.unlock() }

        let wasActive = isActiveLocked
        mutation()
        let isActive = isActiveLocked
        switch (wasActive, isActive) {
        case (false, true):
            return .becameActive
        case (true, false):
            return .becameIdle
        case (false, false), (true, true):
            return .unchanged
        }
    }
}
