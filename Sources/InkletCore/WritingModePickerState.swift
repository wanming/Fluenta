import Foundation

public struct WritingModePickerItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct WritingModePickerState: Equatable, Sendable {
    public private(set) var items: [WritingModePickerItem]
    public private(set) var query: String
    public private(set) var highlightedModeID: String?

    public init(
        items: [WritingModePickerItem],
        preferredModeID: String? = nil,
        query: String = ""
    ) {
        self.items = items
        self.query = query
        highlightedModeID = preferredModeID
        reconcileHighlight()
    }

    public var filteredItems: [WritingModePickerItem] {
        let matchingQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !matchingQuery.isEmpty else {
            return items
        }

        let normalizedQuery = Self.normalizedForSearch(matchingQuery)
        return items.filter {
            Self.normalizedForSearch($0.title).contains(normalizedQuery)
        }
    }

    public mutating func setQuery(_ query: String) {
        self.query = query
        reconcileHighlight()
    }

    public mutating func moveHighlight(by offset: Int) {
        guard offset != 0 else {
            return
        }

        let filteredItems = filteredItems
        guard
            let highlightedModeID,
            let currentIndex = filteredItems.firstIndex(where: { $0.id == highlightedModeID })
        else {
            return
        }

        let (candidateIndex, overflowed) = currentIndex.addingReportingOverflow(offset)
        let targetIndex: Int
        if overflowed {
            targetIndex = offset > 0 ? filteredItems.endIndex - 1 : filteredItems.startIndex
        } else {
            targetIndex = min(
                max(candidateIndex, filteredItems.startIndex),
                filteredItems.endIndex - 1
            )
        }
        self.highlightedModeID = filteredItems[targetIndex].id
    }

    @discardableResult
    public mutating func highlight(modeID: String) -> Bool {
        guard filteredItems.contains(where: { $0.id == modeID }) else {
            return false
        }

        highlightedModeID = modeID
        return true
    }

    private mutating func reconcileHighlight() {
        let filteredItems = filteredItems
        if let highlightedModeID,
           filteredItems.contains(where: { $0.id == highlightedModeID }) {
            return
        }

        highlightedModeID = filteredItems.first?.id
    }

    private static func normalizedForSearch(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
