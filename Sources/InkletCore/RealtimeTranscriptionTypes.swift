import Foundation

public enum RealtimeTranscriptionEvent: Equatable, Sendable {
    case delta(eventID: String?, sequence: Int?, itemID: String, contentIndex: Int, text: String)
    case completed(eventID: String?, sequence: Int?, itemID: String, contentIndex: Int, transcript: String)
}

public enum RealtimeTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case missingAPIKey
    case connectionTimedOut
    case finalTranscriptTimedOut
    case connectionClosed
    case invalidMessage
    case invalidState
    case server(code: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The transcription endpoint is invalid."
        case .missingAPIKey:
            "The transcription API key is missing."
        case .connectionTimedOut:
            "The transcription connection timed out."
        case .finalTranscriptTimedOut:
            "The final transcript timed out."
        case .connectionClosed:
            "The transcription connection closed."
        case .invalidMessage:
            "The transcription message is invalid."
        case .invalidState:
            "The transcription client is in an invalid state."
        case let .server(code, message):
            if let code {
                "The transcription server returned \(code): \(message)"
            } else {
                "The transcription server returned an error: \(message)"
            }
        }
    }
}

public protocol RealtimeTranscriptionClient: Sendable {
    func connect(timeoutSeconds: TimeInterval) async throws
    func appendPCM16(_ data: Data) async throws
    func commit() async throws
    func nextEvent() async throws -> RealtimeTranscriptionEvent
    func close() async
}
