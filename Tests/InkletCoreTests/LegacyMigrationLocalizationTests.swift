import AppKit
import XCTest
@testable import Inklet
@testable import InkletCore

final class LegacyMigrationLocalizationTests: XCTestCase {
    private struct LocalizationEntry {
        let key: String
        let value: String
    }

    private let requiredKeys = [
        "legacyMigration.notice.title",
        "legacyMigration.notice.message",
        "legacyMigration.action.importOldData",
        "legacyMigration.panel.title",
        "legacyMigration.panel.message",
        "legacyMigration.import.progress",
        "legacyMigration.import.invalidSelection",
        "legacyMigration.import.failed",
        "legacyMigration.import.partialFailure",
        "legacyMigration.import.relaunching",
        "legacyMigration.import.relaunchProgress",
        "legacyMigration.import.relaunchFailed",
        "legacyMigration.action.retryRelaunch",
        "legacyMigration.action.quit",
        "legacyMigration.settings.help",
    ]

    private let languageTables = [
        (name: "English", symbol: "en"),
        (name: "Simplified Chinese", symbol: "zhHans"),
        (name: "Traditional Chinese", symbol: "zhHant"),
        (name: "Japanese", symbol: "ja"),
        (name: "Korean", symbol: "ko"),
        (name: "Spanish", symbol: "es"),
        (name: "French", symbol: "fr"),
        (name: "German", symbol: "de"),
        (name: "Portuguese", symbol: "pt"),
        (name: "Italian", symbol: "it"),
    ]

    func testEveryMigrationKeyHasOneNativeValueInEveryLanguageTable() throws {
        let tables = try parsedLanguageTables()

        XCTAssertEqual(tables.count, 10)
        for language in languageTables {
            let entries = try XCTUnwrap(tables[language.symbol])
            XCTAssertEqual(
                Set(entries.map(\.key)),
                Set(requiredKeys),
                "\(language.name) must define the complete migration localization contract"
            )
            for key in requiredKeys {
                XCTAssertEqual(
                    entries.filter { $0.key == key }.count,
                    1,
                    "\(language.name) must define \(key) exactly once"
                )
            }
        }

        for key in requiredKeys {
            let nativeValues = tables.values.flatMap { entries in
                entries.filter { $0.key == key }.map(\.value)
            }
            XCTAssertEqual(nativeValues.count, 10, "\(key) must have exactly ten native entries")
        }

        let english = try XCTUnwrap(tables["en"])
        for language in languageTables.dropFirst() {
            let entries = try XCTUnwrap(tables[language.symbol])
            for key in requiredKeys {
                let englishValue = try value(for: key, in: english)
                let nativeValue = try value(for: key, in: entries)
                XCTAssertNotEqual(
                    nativeValue,
                    englishValue,
                    "\(language.name) must not reuse the English fallback for \(key)"
                )
            }
        }
    }

    func testRepresentativeEnglishAndSimplifiedChineseCopyIsExact() throws {
        let tables = try parsedLanguageTables()
        let english = try XCTUnwrap(tables["en"])
        let simplifiedChinese = try XCTUnwrap(tables["zhHans"])

        XCTAssertEqual(try value(for: "legacyMigration.notice.title", in: english), "Old Inklet data was not imported")
        XCTAssertEqual(
            try value(for: "legacyMigration.notice.message", in: english),
            "Your previous settings and history are still preserved. You can choose the matching Inklet Data folder to import them."
        )
        XCTAssertEqual(try value(for: "legacyMigration.action.importOldData", in: english), "Import Old Data…")
        XCTAssertEqual(try value(for: "legacyMigration.import.progress", in: english), "Importing old data…")
        XCTAssertEqual(
            try value(for: "legacyMigration.import.invalidSelection", in: english),
            "The selected folder is not the legacy data folder for this Inklet app."
        )
        XCTAssertEqual(
            try value(for: "legacyMigration.import.relaunching", in: english),
            "Inklet needs to relaunch to finish loading the imported data."
        )

        XCTAssertEqual(try value(for: "legacyMigration.notice.title", in: simplifiedChinese), "旧版 Inklet 数据尚未导入")
        XCTAssertEqual(
            try value(for: "legacyMigration.notice.message", in: simplifiedChinese),
            "你之前的设置和历史记录仍被保留。你可以选择对应的 Inklet Data 文件夹进行导入。"
        )
        XCTAssertEqual(try value(for: "legacyMigration.action.importOldData", in: simplifiedChinese), "导入旧数据…")
        XCTAssertEqual(try value(for: "legacyMigration.import.progress", in: simplifiedChinese), "正在导入旧数据…")
        XCTAssertEqual(
            try value(for: "legacyMigration.import.invalidSelection", in: simplifiedChinese),
            "所选文件夹不是当前 Inklet 对应的旧数据文件夹。"
        )
        XCTAssertEqual(
            try value(for: "legacyMigration.import.relaunching", in: simplifiedChinese),
            "Inklet 需要重新启动以载入已导入的数据。"
        )
    }

    func testMigrationCopyContainsNoPrivateDetailInterpolationOrPathMaterial() throws {
        let privateDetailTerms = [
            "api key",
            "apikey",
            "credential",
            "password",
            "username",
            "user name",
            "selected text",
            "history contents",
            "raw error",
            "localizeddescription",
        ]

        for (symbol, entries) in try parsedLanguageTables() {
            for entry in entries {
                XCTAssertFalse(entry.value.isEmpty, "\(symbol).\(entry.key) must not be empty")
                XCTAssertFalse(entry.value.contains("%"), "\(symbol).\(entry.key) must not interpolate values")
                XCTAssertFalse(entry.value.contains("$"), "\(symbol).\(entry.key) must not interpolate values")
                XCTAssertFalse(entry.value.contains("/"), "\(symbol).\(entry.key) must not expose a path or URL")
                XCTAssertFalse(entry.value.contains("\\"), "\(symbol).\(entry.key) must not expose a path or interpolate values")

                let normalizedValue = entry.value.lowercased()
                for term in privateDetailTerms {
                    XCTAssertFalse(
                        normalizedValue.contains(term),
                        "\(symbol).\(entry.key) must not expose private \(term) details"
                    )
                }
            }
        }
    }

    func testFixedMigrationButtonLabelsFitConservative132PointTextBudget() throws {
        let buttonWidth: CGFloat = 168
        let horizontalContentAllowance: CGFloat = 16
        let iconOrProgressSlotWidth: CGFloat = 14
        let labelSpacing: CGFloat = 6
        let textWidthBudget = buttonWidth
            - horizontalContentAllowance
            - iconOrProgressSlotWidth
            - labelSpacing
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let buttonLabelKeys = [
            "legacyMigration.action.importOldData",
            "legacyMigration.import.progress",
            "legacyMigration.import.relaunchProgress",
        ]

        XCTAssertEqual(textWidthBudget, 132)
        for language in languageTables {
            let entries = try XCTUnwrap(parsedLanguageTables()[language.symbol])
            for key in buttonLabelKeys {
                guard let label = entries.first(where: { $0.key == key })?.value else {
                    XCTFail("Missing fixed-button label \(language.symbol).\(key)")
                    continue
                }
                let measuredWidth = ceil(
                    (label as NSString).size(withAttributes: [.font: font]).width
                )

                XCTAssertLessThanOrEqual(
                    measuredWidth,
                    textWidthBudget,
                    "\(language.symbol).\(key) measures \(measuredWidth)pt; fixed 168pt button leaves a conservative 132pt text budget after 16pt horizontal allowance, 14pt icon/progress slot, and 6pt label spacing"
                )
            }
        }
    }

    func testRelaunchDetailKeepsFullCopyWhileButtonUsesConciseProgressKey() throws {
        let source = try settingsViewSource()
        let noticeMessage = try sourceScope(
            startingAt: "private var migrationNoticeMessage",
            endingBefore: "@ViewBuilder\n    private var migrationPrimaryAction",
            in: source
        )
        let primaryAction = try sourceScope(
            startingAt: "private var migrationPrimaryAction",
            endingBefore: "private func migrationActionButton",
            in: source
        )

        XCTAssertTrue(noticeMessage.contains("case .relaunching:"))
        XCTAssertTrue(noticeMessage.contains(#"L10n.text("legacyMigration.import.relaunching")"#))
        XCTAssertFalse(noticeMessage.contains("legacyMigration.import.relaunchProgress"))
        XCTAssertTrue(primaryAction.contains(#": "legacyMigration.import.relaunchProgress""#))
        XCTAssertFalse(primaryAction.contains(#": "legacyMigration.import.relaunching""#))
    }

    @MainActor
    func testRuntimeLookupUsesTheNativeValueFromEveryLanguageTable() throws {
        let tables = try parsedLanguageTables()
        let defaults = UserDefaults.standard
        let preferenceKey = InkletPreferenceKeys.interfaceLanguage
        let originalPreference = defaults.object(forKey: preferenceKey)
        defer {
            if let originalPreference {
                defaults.set(originalPreference, forKey: preferenceKey)
            } else {
                defaults.removeObject(forKey: preferenceKey)
            }
        }
        let runtimeLanguages: [(symbol: String, language: InterfaceLanguage)] = [
            ("en", .english),
            ("zhHans", .simplifiedChinese),
            ("zhHant", .traditionalChinese),
            ("ja", .japanese),
            ("ko", .korean),
            ("es", .spanish),
            ("fr", .french),
            ("de", .german),
            ("pt", .portuguese),
            ("it", .italian),
        ]

        XCTAssertEqual(runtimeLanguages.count, 10)
        for runtimeLanguage in runtimeLanguages {
            InkletLanguageStore.selectedLanguage = runtimeLanguage.language
            let entries = try XCTUnwrap(tables[runtimeLanguage.symbol])
            for key in requiredKeys {
                XCTAssertEqual(
                    L10n.text(key),
                    try value(for: key, in: entries),
                    "Runtime lookup must use \(runtimeLanguage.symbol).\(key) without fallback"
                )
            }
        }
    }

    private func parsedLanguageTables() throws -> [String: [LocalizationEntry]] {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let localizationURL = packageRoot.appendingPathComponent("Sources/InkletApp/InkletLocalization.swift")
        let source = try String(contentsOf: localizationURL, encoding: .utf8)
        return try Dictionary(uniqueKeysWithValues: languageTables.map { language in
            (language.symbol, try migrationEntries(in: language.symbol, source: source))
        })
    }

    private func settingsViewSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent("Sources/InkletApp/SettingsView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func sourceScope(
        startingAt startToken: String,
        endingBefore endToken: String,
        in source: String
    ) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: startToken))
        let suffix = source[start.lowerBound...]
        let end = try XCTUnwrap(suffix.range(of: endToken))
        return suffix[..<end.lowerBound]
    }

    private func migrationEntries(in table: String, source: String) throws -> [LocalizationEntry] {
        let startMarker = "private static let \(table): [String: String] = ["
        let startRange = try XCTUnwrap(source.range(of: startMarker), "Missing \(table) localization table")
        let remainder = source[startRange.upperBound...]
        let endRange = try XCTUnwrap(remainder.range(of: "\n    ]"), "Unterminated \(table) localization table")
        let tableSource = String(remainder[..<endRange.lowerBound])
        let expression = try NSRegularExpression(
            pattern: "\\\"(legacyMigration\\.[^\\\"]+)\\\":\\s*\\\"((?:\\\\.|[^\\\"\\\\])*)\\\""
        )
        let range = NSRange(tableSource.startIndex..<tableSource.endIndex, in: tableSource)

        return expression.matches(in: tableSource, range: range).map { match in
            let keyRange = Range(match.range(at: 1), in: tableSource)!
            let valueRange = Range(match.range(at: 2), in: tableSource)!
            return LocalizationEntry(
                key: String(tableSource[keyRange]),
                value: String(tableSource[valueRange])
            )
        }
    }

    private func value(for key: String, in entries: [LocalizationEntry]) throws -> String {
        try XCTUnwrap(entries.first { $0.key == key }?.value, "Missing localization for \(key)")
    }
}
