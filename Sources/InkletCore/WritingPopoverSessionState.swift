public struct WritingPopoverSessionState: Equatable, Sendable {
    public enum Route: Equatable, Sendable {
        case modePicker
        case editor
    }

    public private(set) var route: Route
    public private(set) var selectedModeID: String
    public private(set) var resultModeID: String?

    public init(
        selectedModeID: String,
        route: Route = .modePicker,
        resultModeID: String? = nil
    ) {
        self.route = route
        self.selectedModeID = selectedModeID
        self.resultModeID = resultModeID
    }

    public var isResultStale: Bool {
        resultModeID != nil && resultModeID != selectedModeID
    }

    public mutating func showModePicker() {
        route = .modePicker
    }

    public mutating func enterEditor(modeID: String) {
        selectedModeID = modeID
        route = .editor
    }

    public mutating func recordResult(modeID: String) {
        resultModeID = modeID
    }

    public mutating func clearResult() {
        resultModeID = nil
    }
}
