import XCTest
@testable import InkletCore

final class VoiceInputConfigTests: XCTestCase {
    func testDefaultDictationConfigContainsOnlyLiveFields() {
        XCTAssertEqual(
            VoiceInputConfig.defaultConfig(),
            VoiceInputConfig(
                shortcut: .rightOption,
                speechEndpoint: "https://api.openai.com/v1/audio/transcriptions",
                speechModel: "gpt-4o-mini-transcribe",
                microphoneDeviceID: nil
            )
        )
    }

    func testAppConfigDefaultsIncludeVoiceInputConfig() {
        let config = AppConfig.defaultConfig()

        XCTAssertEqual(config.voiceInput, VoiceInputConfig.defaultConfig())
    }

    func testAppConfigDecodeFallsBackToVoiceDefaultsForMissingFields() throws {
        let data = #"{"model":"saved-model"}"#.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.model, "saved-model")
        XCTAssertEqual(config.voiceInput, VoiceInputConfig.defaultConfig())
    }

    func testAppConfigRoundTripsVoiceInputConfig() throws {
        var config = AppConfig.defaultConfig()
        config.voiceInput = VoiceInputConfig(
            shortcut: .leftCommand,
            speechEndpoint: "https://speech.example.test/v1/audio/transcriptions",
            speechModel: "gpt-4o-transcribe",
            microphoneDeviceID: "BuiltInMicrophoneDeviceID"
        )

        let data = try JSONEncoder().encode(config)
        let decodedConfig = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(decodedConfig.voiceInput, config.voiceInput)
        XCTAssertEqual(decodedConfig.voiceInput.microphoneDeviceID, "BuiltInMicrophoneDeviceID")
    }

    func testV3VoiceConfigurationPreservesFourLiveFieldsAndIgnoresRetiredKeys() throws {
        let json = """
        {
          "shortcut": "leftCommand",
          "speechProviderID": "retired-provider",
          "speechEndpoint": "https://fallback.example/v1/audio/transcriptions",
          "speechModel": "fallback-model",
          "microphoneDeviceID": "mic-123",
          "autoProcessTranscription": false,
          "postTranscriptionAction": "askEachTime",
          "recordingMode": "doubleTap",
          "voiceCleanupPromptModeID": "legacy-cleanup"
        }
        """

        let decoded = try JSONDecoder().decode(VoiceInputConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.shortcut, .leftCommand)
        XCTAssertEqual(decoded.speechEndpoint, "https://fallback.example/v1/audio/transcriptions")
        XCTAssertEqual(decoded.speechModel, "fallback-model")
        XCTAssertEqual(decoded.microphoneDeviceID, "mic-123")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "shortcut", "speechEndpoint", "speechModel", "microphoneDeviceID"
        ])
    }
}
