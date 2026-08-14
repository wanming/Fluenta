import CoreFoundation
import Foundation
import XCTest

final class DirectDistributionContractTests: XCTestCase {
    func testPlistBooleanTrueRejectsNumericLookalikes() throws {
        let propertyList = try propertyList(from: Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
                <key>integer</key>
                <integer>1</integer>
                <key>real</key>
                <real>1.0</real>
                <key>boolean</key>
                <true/>
            </dict>
            </plist>
            """.utf8
        ))

        XCTAssertFalse(isTruePlistBoolean(propertyList["integer"]))
        XCTAssertFalse(isTruePlistBoolean(propertyList["real"]))
        XCTAssertTrue(isTruePlistBoolean(propertyList["boolean"]))
    }

    func testEntitlementsContainOnlyDirectDistributionMicrophoneAccess() throws {
        let entitlements = try propertyList(at: repositoryRoot
            .appendingPathComponent("StoreSupport/Inklet.entitlements"))
        let expected: [String: Any] = [
            "com.apple.security.device.audio-input": true
        ]

        XCTAssertEqual(entitlements as NSDictionary, expected as NSDictionary)
        XCTAssertTrue(isTruePlistBoolean(entitlements["com.apple.security.device.audio-input"]))

        let forbiddenKeys = [
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
            "com.apple.security.device.microphone",
            "com.apple.security.automation.apple-events",
            "com.apple.security.get-task-allow"
        ]
        for key in forbiddenKeys {
            XCTAssertNil(entitlements[key], "Direct distribution must not include \(key)")
        }
    }

    func testInfoPlistDeclaresOnlyMicrophonePrivacyUsage() throws {
        let infoPlist = try propertyList(at: repositoryRoot
            .appendingPathComponent("StoreSupport/Info.plist"))
        let microphoneUsageDescription = try XCTUnwrap(
            infoPlist["NSMicrophoneUsageDescription"] as? String
        )

        XCTAssertFalse(
            microphoneUsageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        XCTAssertNil(infoPlist["NSAppleEventsUsageDescription"])
    }

    func testAllLocalizedInfoPlistStringsDeclareOnlyMicrophonePrivacyUsage() throws {
        let localizationsRoot = repositoryRoot
            .appendingPathComponent("StoreSupport/InfoPlistStrings", isDirectory: true)
        let expectedLocalizationPaths: Set<String> = [
            "de.lproj/InfoPlist.strings",
            "en.lproj/InfoPlist.strings",
            "es.lproj/InfoPlist.strings",
            "fr.lproj/InfoPlist.strings",
            "it.lproj/InfoPlist.strings",
            "ja.lproj/InfoPlist.strings",
            "ko.lproj/InfoPlist.strings",
            "pt.lproj/InfoPlist.strings",
            "zh-Hans.lproj/InfoPlist.strings",
            "zh-Hant.lproj/InfoPlist.strings"
        ]
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: localizationsRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ))
        var localizationURLs: [URL] = []

        for case let fileURL as URL in enumerator
            where fileURL.lastPathComponent == "InfoPlist.strings"
        {
            let resourceValues = try fileURL.resourceValues(forKeys: resourceKeys)
            guard resourceValues.isRegularFile == true else {
                continue
            }
            localizationURLs.append(fileURL)
        }

        localizationURLs.sort { $0.path < $1.path }
        let discoveredLocalizationPaths = Set(localizationURLs.map { localizationURL in
            localizationURL.pathComponents
                .dropFirst(localizationsRoot.pathComponents.count)
                .joined(separator: "/")
        })
        let missingPaths = expectedLocalizationPaths.subtracting(discoveredLocalizationPaths)
        let unexpectedPaths = discoveredLocalizationPaths.subtracting(expectedLocalizationPaths)

        XCTAssertEqual(localizationURLs.count, 10)
        XCTAssertEqual(
            discoveredLocalizationPaths,
            expectedLocalizationPaths,
            """
            Localized InfoPlist.strings paths differ.
            Missing: \(missingPaths.sorted())
            Unexpected: \(unexpectedPaths.sorted())
            """
        )

        for localizationURL in localizationURLs {
            let localizedStrings = try propertyList(at: localizationURL)
            let microphoneUsageDescription = try XCTUnwrap(
                localizedStrings["NSMicrophoneUsageDescription"] as? String,
                "Missing microphone privacy copy in \(localizationURL.path)"
            )

            XCTAssertFalse(
                microphoneUsageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Empty microphone privacy copy in \(localizationURL.path)"
            )
            XCTAssertNil(
                localizedStrings["NSAppleEventsUsageDescription"],
                "Unexpected Apple Events privacy copy in \(localizationURL.path)"
            )
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private func propertyList(at fileURL: URL) throws -> [String: Any] {
        try propertyList(from: Data(contentsOf: fileURL))
    }

    private func propertyList(from data: Data) throws -> [String: Any] {
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(propertyList as? [String: Any])
    }

    private func isTruePlistBoolean(_ value: Any?) -> Bool {
        guard let value,
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
        else {
            return false
        }
        return (value as? Bool) == true
    }
}
