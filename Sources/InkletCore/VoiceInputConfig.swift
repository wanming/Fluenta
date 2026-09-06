import Foundation

public struct VoiceInputConfig: Codable, Equatable, Sendable {
    public static let defaultSpeechEndpoint = "https://api.openai.com/v1/audio/transcriptions"
    public static let defaultSpeechModel = "gpt-4o-mini-transcribe"

    public enum Shortcut: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
        case rightOption
        case rightCommand
        case leftOption
        case leftCommand
        case disabled

        public var id: String { rawValue }
    }

    public var shortcut: Shortcut
    public private(set) var speechEndpoint: String
    public var speechModel: String
    public var microphoneDeviceID: String?

    public init(
        shortcut: Shortcut,
        speechModel: String,
        microphoneDeviceID: String?
    ) {
        self.shortcut = shortcut
        self.speechEndpoint = Self.defaultSpeechEndpoint
        self.speechModel = speechModel
        self.microphoneDeviceID = microphoneDeviceID
    }

    public static func defaultConfig() -> VoiceInputConfig {
        VoiceInputConfig(
            shortcut: .rightOption,
            speechModel: defaultSpeechModel,
            microphoneDeviceID: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case shortcut
        case speechEndpoint
        case speechModel
        case microphoneDeviceID
    }

    public init(from decoder: Decoder) throws {
        let defaults = Self.defaultConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try container.decodeIfPresent(Shortcut.self, forKey: .shortcut) ?? defaults.shortcut
        _ = try container.decodeIfPresent(String.self, forKey: .speechEndpoint)
        speechEndpoint = Self.defaultSpeechEndpoint
        speechModel = try container.decodeIfPresent(String.self, forKey: .speechModel)
            ?? defaults.speechModel
        microphoneDeviceID = try container.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shortcut, forKey: .shortcut)
        try container.encode(Self.defaultSpeechEndpoint, forKey: .speechEndpoint)
        try container.encode(speechModel, forKey: .speechModel)
        try container.encodeIfPresent(microphoneDeviceID, forKey: .microphoneDeviceID)
    }
}
