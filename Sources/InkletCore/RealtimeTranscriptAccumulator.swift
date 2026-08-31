public struct RealtimeTranscriptAccumulator: Equatable, Sendable {
    private struct StreamIdentity: Equatable, Sendable {
        let itemID: String
        let contentIndex: Int
    }

    public enum Update: Equatable, Sendable {
        case ignored
        case provisional(String)
        case final(String)
    }

    private var identity: StreamIdentity?
    private var transcript = ""
    private var seenEventIDs = Set<String>()
    private var lastSequence: Int?
    private var isComplete = false

    public init() {}

    public mutating func accept(_ event: RealtimeTranscriptionEvent) -> Update {
        guard !isComplete else { return .ignored }

        let eventIdentity: StreamIdentity
        let eventID: String?
        let sequence: Int?
        switch event {
        case let .delta(id, sequenceValue, itemID, contentIndex, _):
            eventIdentity = StreamIdentity(itemID: itemID, contentIndex: contentIndex)
            eventID = id
            sequence = sequenceValue
        case let .completed(id, sequenceValue, itemID, contentIndex, _):
            eventIdentity = StreamIdentity(itemID: itemID, contentIndex: contentIndex)
            eventID = id
            sequence = sequenceValue
        }

        if let identity, identity != eventIdentity {
            return .ignored
        }
        if identity == nil {
            identity = eventIdentity
        }
        if let eventID, seenEventIDs.contains(eventID) {
            return .ignored
        }
        if let sequence, let lastSequence, sequence <= lastSequence {
            return .ignored
        }

        if let eventID {
            seenEventIDs.insert(eventID)
        }
        if let sequence {
            lastSequence = sequence
        }

        switch event {
        case let .delta(_, _, _, _, text):
            transcript.append(text)
            return .provisional(transcript)
        case let .completed(_, _, _, _, authoritativeTranscript):
            transcript = authoritativeTranscript
            isComplete = true
            return .final(authoritativeTranscript)
        }
    }
}
