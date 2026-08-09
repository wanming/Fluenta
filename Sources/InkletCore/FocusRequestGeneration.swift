public struct FocusRequestGeneration: Equatable, Sendable {
    public struct Request: Equatable, Sendable {
        fileprivate let revision: UInt64
    }

    private var revision: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func issue() -> Request {
        revision += 1
        return Request(revision: revision)
    }

    public mutating func invalidate() {
        revision += 1
    }

    public func isCurrent(_ request: Request) -> Bool {
        request.revision == revision
    }
}
