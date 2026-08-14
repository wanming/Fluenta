import Foundation

public enum SelectionMouseUpAction: Equatable, Sendable {
    case candidateSelection
    case dismiss
    case ignore
}

public struct SelectionDragPolicy: Equatable, Sendable {
    private let minimumDistance: Double
    private var startPoint: SelectionPoint?

    public init(minimumDistance: Double = 6) {
        self.minimumDistance = minimumDistance
    }

    public mutating func recordMouseDown(at point: SelectionPoint) {
        startPoint = point
    }

    public mutating func consumeMouseUp(at point: SelectionPoint) -> Bool {
        consumeMouseUpAction(at: point) == .candidateSelection
    }

    public mutating func consumeMouseUpAction(at point: SelectionPoint, clickCount: Int = 1) -> SelectionMouseUpAction {
        defer {
            startPoint = nil
        }

        if clickCount >= 2 {
            return .candidateSelection
        }

        guard let startPoint else {
            return .ignore
        }

        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        return (dx * dx + dy * dy).squareRoot() >= minimumDistance ? .candidateSelection : .dismiss
    }
}
