import Foundation
import XCTest
@testable import Inklet
@testable import InkletCore

final class LocalizationCoverageTests: XCTestCase {
    func testEveryLanguageDefinesEveryLocalizationKey() throws {
        let tables = L10n.translationTables
        let baseline = try XCTUnwrap(tables[.english])
        XCTAssertEqual(Set(tables.keys), Set(InterfaceLanguage.allCases.filter { $0 != .system }))
        XCTAssertFalse(baseline.isEmpty)

        for (language, table) in tables {
            let missing = Set(baseline.keys).subtracting(table.keys).sorted()
            let extra = Set(table.keys).subtracting(baseline.keys).sorted()
            XCTAssertTrue(missing.isEmpty, "Missing translations in \(language): \(missing)")
            XCTAssertTrue(extra.isEmpty, "Unknown translations in \(language): \(extra)")
            for (key, value) in table {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty \(language).\(key)")
            }
        }
    }

    func testAllTranslationsPreserveFormatArgumentsAndNamedTokens() throws {
        let baseline = try XCTUnwrap(L10n.translationTables[.english])
        for (language, table) in L10n.translationTables {
            for (key, value) in table {
                let english = try XCTUnwrap(baseline[key])
                XCTAssertEqual(try placeholders(in: value), try placeholders(in: english), "Format mismatch in \(language).\(key)")
                XCTAssertEqual(try namedTokens(in: value), try namedTokens(in: english), "Named token mismatch in \(language).\(key)")
            }
        }
    }

    func testLiteralLocalizationReferencesExistInTheCatalog() throws {
        let baseline = try XCTUnwrap(L10n.translationTables[.english])
        let sources = packageRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let regex = try NSRegularExpression(pattern: #"L10n\.(?:text|format)\(\s*"([^"\\]+)""#)
        var referenceCount = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let key = String(source[try XCTUnwrap(Range(match.range(at: 1), in: source))])
                referenceCount += 1
                XCTAssertNotNil(baseline[key], "Unknown localization key \(key) in \(file.lastPathComponent)")
            }
        }
        XCTAssertGreaterThan(referenceCount, 0)
    }

    func testSystemLanguageHonorsTheFirstSupportedPreferenceIncludingEnglish() {
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["en-US", "ja-JP"]), .english)
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["ja-JP", "en-US"]), .japanese)
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["nl-NL", "en-GB", "de-DE"]), .english)
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["nl-NL", "fr-CA", "en-US"]), .french)
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["nl-NL"]), .english)
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: []), .english)
    }

    func testUserInterfaceLiteralsAreLocalizedOrExplicitlyLanguageNeutral() throws {
        let allowedLiterals: Set<String> = [
            "", "Inklet", "© 2026 Inklet",
            #"\(model.currentProviderName) · \(model.currentModelName)"#,
        ]
        let patterns = [
            #"\b(?:Text|Button|Label|Toggle|Picker|Menu)\(\s*"((?:[^"\\]|\\.)*)""#,
            #"\b(?:help|accessibilityLabel|setAccessibilityLabel)\(\s*"((?:[^"\\]|\\.)*)""#,
            #"\bNSMenu(?:Item)?\(\s*title:\s*"((?:[^"\\]|\\.)*)""#,
        ]
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        let sources = packageRoot.appendingPathComponent("Sources/InkletApp")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for regex in regexes {
                for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    let literal = String(source[try XCTUnwrap(Range(match.range(at: 1), in: source))])
                    XCTAssertTrue(allowedLiterals.contains(literal), "Localize UI copy in \(file.lastPathComponent): \(literal)")
                }
            }
        }
    }

    func testPermissionDescriptionsCoverEverySupportedBundleLanguage() throws {
        let resources = packageRoot.appendingPathComponent("StoreSupport/InfoPlistStrings")
        let folders = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        let supportedLocales = Set(InterfaceLanguage.allCases.filter { $0 != .system }.map(\.localeIdentifier))
        XCTAssertEqual(Set(folders.map { $0.deletingPathExtension().lastPathComponent }), supportedLocales)

        func entries(in folder: URL) throws -> [String: String] {
            let data = try Data(contentsOf: folder.appendingPathComponent("InfoPlist.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }

        let english = try entries(in: resources.appendingPathComponent("en.lproj"))
        XCTAssertNotNil(english["NSMicrophoneUsageDescription"])
        for folder in folders {
            let table = try entries(in: folder)
            XCTAssertEqual(Set(table.keys), Set(english.keys), "Incomplete permission descriptions: \(folder.lastPathComponent)")
            for (key, value) in table {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty \(folder.lastPathComponent).\(key)")
            }
        }
    }

    func testSystemLanguageRecognizesEverySupportedLanguage() {
        for language in InterfaceLanguage.allCases where language != .system {
            XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: [language.localeIdentifier]), language)
        }
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["PT_br"]), .portuguese)
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["es-MX"]), .spanish)
        XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: ["english", "de-DE"]), .german)
    }

    func testChineseScriptTakesPrecedenceOverRegion() {
        for identifier in ["zh-TW", "zh-HK", "zh-MO", "zh-Hant", "zh_Hant_CN"] {
            XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: [identifier]), .traditionalChinese, identifier)
        }
        for identifier in ["zh", "zh-CN", "zh-SG", "zh-Hans", "zh-Hans-HK", "ZH_hans_TW"] {
            XCTAssertEqual(L10n.resolveLanguage(preferredLanguages: [identifier]), .simplifiedChinese, identifier)
        }
    }

    func testExplicitLanguageControlsRuntimeLookupAndNumberFormatting() {
        withLanguage(.english) {
            XCTAssertEqual(L10n.resolvedLanguage, .english)
            XCTAssertEqual(L10n.format("settings.aiPronunciation.speedValue", 1.25), "1.25x")
            XCTAssertEqual(L10n.text("app.menu.copy"), "Copy")
        }
        withLanguage(.french) {
            XCTAssertEqual(L10n.resolvedLanguage, .french)
            XCTAssertEqual(L10n.format("settings.aiPronunciation.speedValue", 1.25), "1,25x")
            XCTAssertEqual(L10n.text("app.menu.copy"), "Copier")
        }
        withLanguage(.german) {
            XCTAssertEqual(L10n.format("settings.aiPronunciation.speedValue", 1.25), "1,25x")
            XCTAssertEqual(L10n.text("settings.section.writeAssistant"), "Schreibassistent")
        }
    }

    private func withLanguage(_ language: InterfaceLanguage, operation: () -> Void) {
        let savedDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(savedDomain, forName: UserDefaults.argumentDomain) }
        var domain = savedDomain
        domain[InkletPreferenceKeys.interfaceLanguage] = language.rawValue
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        operation()
    }

    private func placeholders(in value: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?[-+ #0]*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(?:hh|h|ll|l|L|z|j|t)?[@diuoxXfFeEgGaAcCsSp]"#)
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
            String(value[Range($0.range, in: value)!])
        }
    }

    private func namedTokens(in value: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"\{[A-Za-z][A-Za-z0-9]*\}"#)
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
            String(value[Range($0.range, in: value)!])
        }.sorted()
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
