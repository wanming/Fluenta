import Foundation
import XCTest

final class WritingModeLauncherLocalizationTests: XCTestCase {
    private let approvedTableIDs = [
        "en",
        "zhHans",
        "zhHant",
        "ja",
        "ko",
        "es",
        "fr",
        "de",
        "pt",
        "it",
    ]

    private let launcherKeys = [
        "popover.modeSearch.placeholder",
        "popover.modeSearch.empty",
        "popover.modeSearch.select",
        "popover.modeSearch.write",
        "popover.result.generatedWith",
        "popover.action.regenerate",
        "popover.mode.backToModes",
    ]

    private let expectedLauncherValues = [
        "en": [
            "popover.modeSearch.placeholder": "Search modes",
            "popover.modeSearch.empty": "No matching modes",
            "popover.modeSearch.select": "Select",
            "popover.modeSearch.write": "Write",
            "popover.result.generatedWith": "Generated with %@",
            "popover.action.regenerate": "Regenerate",
            "popover.mode.backToModes": "Choose mode",
        ],
        "zhHans": [
            "popover.modeSearch.placeholder": "搜索模式",
            "popover.modeSearch.empty": "没有匹配的模式",
            "popover.modeSearch.select": "选择",
            "popover.modeSearch.write": "写作",
            "popover.result.generatedWith": "由 %@ 生成",
            "popover.action.regenerate": "重新生成",
            "popover.mode.backToModes": "选择模式",
        ],
        "zhHant": [
            "popover.modeSearch.placeholder": "搜尋模式",
            "popover.modeSearch.empty": "沒有相符的模式",
            "popover.modeSearch.select": "選擇",
            "popover.modeSearch.write": "寫作",
            "popover.result.generatedWith": "由 %@ 產生",
            "popover.action.regenerate": "重新產生",
            "popover.mode.backToModes": "選擇模式",
        ],
        "ja": [
            "popover.modeSearch.placeholder": "モードを検索",
            "popover.modeSearch.empty": "一致するモードがありません",
            "popover.modeSearch.select": "選択",
            "popover.modeSearch.write": "入力",
            "popover.result.generatedWith": "%@ で生成",
            "popover.action.regenerate": "再生成",
            "popover.mode.backToModes": "モードを選択",
        ],
        "ko": [
            "popover.modeSearch.placeholder": "모드 검색",
            "popover.modeSearch.empty": "일치하는 모드 없음",
            "popover.modeSearch.select": "선택",
            "popover.modeSearch.write": "작성",
            "popover.result.generatedWith": "%@로 생성",
            "popover.action.regenerate": "다시 생성",
            "popover.mode.backToModes": "모드 선택",
        ],
        "es": [
            "popover.modeSearch.placeholder": "Buscar modos",
            "popover.modeSearch.empty": "No hay modos coincidentes",
            "popover.modeSearch.select": "Seleccionar",
            "popover.modeSearch.write": "Escribir",
            "popover.result.generatedWith": "Generado con %@",
            "popover.action.regenerate": "Regenerar",
            "popover.mode.backToModes": "Elegir modo",
        ],
        "fr": [
            "popover.modeSearch.placeholder": "Rechercher des modes",
            "popover.modeSearch.empty": "Aucun mode correspondant",
            "popover.modeSearch.select": "Sélectionner",
            "popover.modeSearch.write": "Écrire",
            "popover.result.generatedWith": "Généré avec %@",
            "popover.action.regenerate": "Régénérer",
            "popover.mode.backToModes": "Choisir un mode",
        ],
        "de": [
            "popover.modeSearch.placeholder": "Modi suchen",
            "popover.modeSearch.empty": "Keine passenden Modi",
            "popover.modeSearch.select": "Auswählen",
            "popover.modeSearch.write": "Schreiben",
            "popover.result.generatedWith": "Mit %@ erstellt",
            "popover.action.regenerate": "Neu generieren",
            "popover.mode.backToModes": "Modus wählen",
        ],
        "pt": [
            "popover.modeSearch.placeholder": "Buscar modos",
            "popover.modeSearch.empty": "Nenhum modo correspondente",
            "popover.modeSearch.select": "Selecionar",
            "popover.modeSearch.write": "Escrever",
            "popover.result.generatedWith": "Gerado com %@",
            "popover.action.regenerate": "Gerar novamente",
            "popover.mode.backToModes": "Escolher modo",
        ],
        "it": [
            "popover.modeSearch.placeholder": "Cerca modalità",
            "popover.modeSearch.empty": "Nessuna modalità corrispondente",
            "popover.modeSearch.select": "Seleziona",
            "popover.modeSearch.write": "Scrivi",
            "popover.result.generatedWith": "Generato con %@",
            "popover.action.regenerate": "Rigenera",
            "popover.mode.backToModes": "Scegli modalità",
        ],
    ]

    func testLocalizationTableDeclarationsMatchApprovedTables() throws {
        let source = try localizationSource()
        let declaredTableIDs = try localizationTableIDs(in: source)

        XCTAssertEqual(Set(declaredTableIDs), Set(approvedTableIDs))
        XCTAssertEqual(declaredTableIDs.count, approvedTableIDs.count)
        XCTAssertEqual(Set(expectedLauncherValues.keys), Set(approvedTableIDs))
    }

    func testLauncherCopyMatchesEveryApprovedLocalizationTable() throws {
        let source = try localizationSource()

        for tableID in approvedTableIDs {
            let tableSource = try localizationTableSource(tableID, in: source)
            guard let expectedValues = expectedLauncherValues[tableID] else {
                XCTFail("Missing approved translations for \(tableID)")
                continue
            }

            XCTAssertEqual(
                Set(expectedValues.keys),
                Set(launcherKeys),
                "Unexpected launcher translation fixture for \(tableID)"
            )

            let normalizedEntries = normalizedDictionaryEntries(in: tableSource)
            for key in launcherKeys {
                guard let expectedValue = expectedValues[key] else {
                    XCTFail("Missing expected \(key) value for \(tableID)")
                    continue
                }

                XCTAssertEqual(
                    countDictionaryEntries(key, in: tableSource),
                    1,
                    "Expected exactly one \(key) entry in \(tableID)"
                )
                XCTAssertTrue(
                    normalizedEntries.contains(#""\#(key)": "\#(expectedValue)""#),
                    "Unexpected \(key) value in \(tableID)"
                )
            }

            guard let generatedWithEntry = normalizedEntries.first(where: {
                $0.hasPrefix(#""popover.result.generatedWith":"#)
            }) else {
                XCTFail("Missing popover.result.generatedWith entry in \(tableID)")
                continue
            }
            XCTAssertEqual(
                generatedWithEntry.components(separatedBy: "%@").count - 1,
                1,
                "Expected one %@ placeholder in \(tableID) popover.result.generatedWith"
            )
        }
    }

    private func localizationSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let localizationURL = packageRoot.appendingPathComponent("Sources/InkletApp/InkletLocalization.swift")
        return try String(contentsOf: localizationURL, encoding: .utf8)
    }

    private func localizationTableIDs(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(
            pattern: #"^[ \t]*private[ \t]+static[ \t]+let[ \t]+([A-Za-z_][A-Za-z0-9_]*):[ \t]*\[String:[ \t]*String\][ \t]*=[ \t]*\["#,
            options: .anchorsMatchLines
        )
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)

        return regex.matches(in: source, range: sourceRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        }
    }

    private func localizationTableSource(_ tableID: String, in source: String) throws -> String {
        let declaration = "    private static let \(tableID): [String: String] = ["
        let declarationRange = try XCTUnwrap(
            source.range(of: declaration),
            "Missing localization table declaration for \(tableID)"
        )
        let tableStart = declarationRange.upperBound
        let tableEnd = try XCTUnwrap(
            source.range(of: "\n    ]", range: tableStart..<source.endIndex),
            "Missing localization table terminator for \(tableID)"
        )
        return String(source[tableStart..<tableEnd.lowerBound])
    }

    private func normalizedDictionaryEntries(in tableSource: String) -> [String] {
        tableSource.split(separator: "\n").map { line in
            let entry = line.trimmingCharacters(in: .whitespaces)
            return entry.hasSuffix(",") ? String(entry.dropLast()) : entry
        }
    }

    private func countDictionaryEntries(_ key: String, in source: String) -> Int {
        source.components(separatedBy: #""\#(key)":"#).count - 1
    }
}
