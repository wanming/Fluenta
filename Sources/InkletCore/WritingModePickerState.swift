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
    private static let exactMatchBonus = 2_000
    private static let prefixMatchBonus = 1_000
    private static let matchedCharacterScore = 100
    private static let consecutiveMatchBonus = 60
    private static let wordStartBonus = 45
    private static let maximumEarlyMatchBonus = 24
    private static let nonconsecutiveGapPenalty = 6
    private static let unmatchedTitleCharacterPenalty = 1
    private static let unreachableScore = Int.min / 4

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
        let rankedItems: [(item: WritingModePickerItem, index: Int, score: Int)] = items.enumerated().compactMap { index, item in
            let normalizedTitle = Self.normalizedForSearch(item.title)
            guard let score = Self.fuzzyScore(
                normalizedQuery: normalizedQuery,
                normalizedTitle: normalizedTitle
            ) else {
                return nil
            }

            return (item: item, index: index, score: score)
        }
        return rankedItems.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }
        .map(\.item)
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

    private static func fuzzyScore(normalizedQuery: String, normalizedTitle: String) -> Int? {
        let queryCharacters = Array(normalizedQuery)
        let titleCharacters = Array(normalizedTitle)
        guard
            !queryCharacters.isEmpty,
            !titleCharacters.isEmpty,
            queryCharacters.count <= titleCharacters.count
        else {
            return nil
        }

        var previous = [Int](repeating: Self.unreachableScore, count: titleCharacters.count)

        for titleIndex in titleCharacters.indices where titleCharacters[titleIndex] == queryCharacters[0] {
            previous[titleIndex] = characterScore(
                at: titleIndex,
                in: titleCharacters
            )
        }
        guard previous.contains(where: { $0 != Self.unreachableScore }) else {
            return nil
        }

        for queryIndex in queryCharacters.indices.dropFirst() {
            var current = [Int](repeating: Self.unreachableScore, count: titleCharacters.count)
            var bestWeightedGappedPredecessor = Self.unreachableScore

            for titleIndex in titleCharacters.indices {
                if titleIndex >= 2 {
                    let gappedPredecessorIndex = titleIndex - 2
                    let gappedPredecessorScore = previous[gappedPredecessorIndex]
                    if gappedPredecessorScore != Self.unreachableScore {
                        bestWeightedGappedPredecessor = max(
                            bestWeightedGappedPredecessor,
                            gappedPredecessorScore
                                + Self.nonconsecutiveGapPenalty * gappedPredecessorIndex
                        )
                    }
                }

                guard titleCharacters[titleIndex] == queryCharacters[queryIndex] else {
                    continue
                }

                var bestScore = Self.unreachableScore
                if titleIndex > 0, previous[titleIndex - 1] != Self.unreachableScore {
                    bestScore = previous[titleIndex - 1] + Self.consecutiveMatchBonus
                }
                if bestWeightedGappedPredecessor != Self.unreachableScore {
                    let gappedScore = bestWeightedGappedPredecessor
                        - Self.nonconsecutiveGapPenalty * (titleIndex - 1)
                    bestScore = max(bestScore, gappedScore)
                }

                guard bestScore != Self.unreachableScore else {
                    continue
                }
                current[titleIndex] = bestScore + characterScore(
                    at: titleIndex,
                    in: titleCharacters
                )
            }
            guard current.contains(where: { $0 != Self.unreachableScore }) else {
                return nil
            }

            previous = current
        }

        var bestScore = Self.unreachableScore
        for titleIndex in titleCharacters.indices where previous[titleIndex] != Self.unreachableScore {
            bestScore = max(bestScore, previous[titleIndex])
        }
        guard bestScore != Self.unreachableScore else {
            return nil
        }

        bestScore -= (titleCharacters.count - queryCharacters.count) * Self.unmatchedTitleCharacterPenalty

        if normalizedTitle == normalizedQuery {
            bestScore += Self.exactMatchBonus
        } else if normalizedTitle.hasPrefix(normalizedQuery) {
            bestScore += Self.prefixMatchBonus
        }
        return bestScore
    }

    private static func characterScore(at index: Int, in title: [Character]) -> Int {
        var score = Self.matchedCharacterScore + max(0, Self.maximumEarlyMatchBonus - index)
        if isWordStart(at: index, in: title) {
            score += Self.wordStartBonus
        }
        return score
    }

    private static func isWordStart(at index: Int, in title: [Character]) -> Bool {
        index == 0 || (isWordCharacter(title[index]) && !isWordCharacter(title[index - 1]))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }
}
