import XCTest
@testable import InkletCore

final class VoiceInputConfigTests: XCTestCase {
    func testLegacySpeechEndpointsNormalizeToCanonicalOpenAIEndpoint() throws {
        let legacyEndpoints = [
            ("custom HTTPS", "https://speech.example.test/v1/audio/transcriptions"),
            ("plaintext HTTP", "http://speech.example.test/v1/audio/transcriptions"),
            ("malformed", "not a URL"),
            ("credentials", "https://user:password@speech.example.test/transcribe"),
            ("port and query", "https://speech.example.test:8443/transcribe?token=secret")
        ]

        for (scenario, legacyEndpoint) in legacyEndpoints {
            let data = try JSONSerialization.data(withJSONObject: [
                "shortcut": "leftCommand",
                "speechEndpoint": legacyEndpoint,
                "speechModel": "legacy-model",
                "microphoneDeviceID": "legacy-mic"
            ])

            let decoded = try JSONDecoder().decode(VoiceInputConfig.self, from: data)

            XCTAssertEqual(
                decoded.speechEndpoint,
                VoiceInputConfig.defaultSpeechEndpoint,
                "Expected \(scenario) endpoint to normalize"
            )
            XCTAssertEqual(decoded.shortcut, .leftCommand)
            XCTAssertEqual(decoded.speechModel, "legacy-model")
            XCTAssertEqual(decoded.microphoneDeviceID, "legacy-mic")
        }
    }

    func testLegacySpeechEndpointRejectsNonStringValues() throws {
        let invalidEndpoints: [(String, Any)] = [
            ("number", 42),
            ("object", ["url": "https://speech.example.test/transcribe"])
        ]

        for (scenario, invalidEndpoint) in invalidEndpoints {
            let data = try JSONSerialization.data(withJSONObject: [
                "speechEndpoint": invalidEndpoint
            ])

            do {
                _ = try JSONDecoder().decode(VoiceInputConfig.self, from: data)
                XCTFail("Expected \(scenario) endpoint to fail type validation")
            } catch DecodingError.typeMismatch(let type, let context) {
                XCTAssertTrue(type == String.self)
                XCTAssertEqual(context.codingPath.last?.stringValue, "speechEndpoint")
            } catch {
                XCTFail("Expected typeMismatch for \(scenario), received \(error)")
            }
        }
    }

    func testEncodingAlwaysWritesCanonicalOpenAIRecoveryEndpoint() throws {
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "speechEndpoint": "https://speech.example.test/v1/audio/transcriptions"
        ])
        let decoded = try JSONDecoder().decode(VoiceInputConfig.self, from: legacyData)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )

        XCTAssertEqual(
            object["speechEndpoint"] as? String,
            VoiceInputConfig.defaultSpeechEndpoint
        )
    }

    func testDefaultDictationConfigContainsOnlyLiveFields() {
        XCTAssertEqual(
            VoiceInputConfig.defaultConfig(),
            VoiceInputConfig(
                shortcut: .rightOption,
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
            speechModel: "gpt-4o-transcribe",
            microphoneDeviceID: "BuiltInMicrophoneDeviceID"
        )

        let data = try JSONEncoder().encode(config)
        let decodedConfig = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(decodedConfig.voiceInput, config.voiceInput)
        XCTAssertEqual(
            decodedConfig.voiceInput.speechEndpoint,
            VoiceInputConfig.defaultSpeechEndpoint
        )
        XCTAssertEqual(decodedConfig.voiceInput.microphoneDeviceID, "BuiltInMicrophoneDeviceID")
    }

    func testV3VoiceConfigurationNormalizesEndpointAndIgnoresRetiredKeys() throws {
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
        XCTAssertEqual(decoded.speechEndpoint, VoiceInputConfig.defaultSpeechEndpoint)
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
