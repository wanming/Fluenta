import Foundation
import XCTest
@testable import Inklet
@testable import InkletCore

final class UpdateCheckLocalizationTests: XCTestCase {
    private let approvedTableIDs = ["en", "zhHans", "zhHant", "ja", "ko", "es", "fr", "de", "pt", "it"]

    private let updateCheckKeys = [
        "app.menu.checkForUpdates",
        "app.menu.checkingForUpdates",
        "update.available.title",
        "update.available.latestVersion",
        "update.available.currentVersion",
        "update.available.noNotes",
        "update.action.viewOnGitHub",
        "update.action.later",
        "update.upToDate.title",
        "update.upToDate.message",
        "update.error.title",
        "update.error.message",
        "update.action.retry",
        "update.action.cancel",
    ]

    private let expectedValues = [
        "en": ["Check for Updates…", "Checking for Updates…", "An Inklet update is available", "Latest: %@ (build %d)", "Current: %@", "View the release on GitHub for details.", "View on GitHub", "Later", "Inklet is up to date", "You’re using %@.", "Couldn’t check for updates", "Check your internet connection and try again.", "Retry", "Cancel"],
        "zhHans": ["检查更新…", "正在检查更新…", "Inklet 有可用更新", "最新版本：%@（构建 %d）", "当前版本：%@", "请前往 GitHub 查看发布详情。", "在 GitHub 上查看", "稍后", "Inklet 已是最新版本", "你正在使用 %@。", "无法检查更新", "请检查网络连接后重试。", "重试", "取消"],
        "zhHant": ["檢查更新…", "正在檢查更新…", "Inklet 有可用更新", "最新版本：%@（組建 %d）", "目前版本：%@", "請前往 GitHub 查看發布詳情。", "在 GitHub 上查看", "稍後", "Inklet 已是最新版本", "你正在使用 %@。", "無法檢查更新", "請檢查網路連線後再試一次。", "重試", "取消"],
        "ja": ["アップデートを確認…", "アップデートを確認中…", "Inklet のアップデートがあります", "最新: %@（ビルド %d）", "現在: %@", "詳細はGitHubのリリースをご覧ください。", "GitHubで表示", "後で", "Inkletは最新です", "%@ を使用しています。", "アップデートを確認できませんでした", "インターネット接続を確認して、もう一度お試しください。", "再試行", "キャンセル"],
        "ko": ["업데이트 확인…", "업데이트 확인 중…", "Inklet 업데이트가 있습니다", "최신: %@ (빌드 %d)", "현재: %@", "자세한 내용은 GitHub 릴리스를 확인하세요.", "GitHub에서 보기", "나중에", "Inklet이 최신 버전입니다", "%@을 사용하고 있습니다.", "업데이트를 확인할 수 없습니다", "인터넷 연결을 확인한 후 다시 시도하세요.", "재시도", "취소"],
        "es": ["Buscar actualizaciones…", "Buscando actualizaciones…", "Hay una actualización de Inklet disponible", "Última: %@ (compilación %d)", "Actual: %@", "Consulta la versión en GitHub para obtener más detalles.", "Ver en GitHub", "Más tarde", "Inklet está actualizado", "Estás usando %@.", "No se pudieron buscar actualizaciones", "Comprueba tu conexión a internet e inténtalo de nuevo.", "Reintentar", "Cancelar"],
        "fr": ["Rechercher des mises à jour…", "Recherche des mises à jour…", "Une mise à jour d’Inklet est disponible", "Dernière version : %@ (build %d)", "Actuelle : %@", "Consultez la publication sur GitHub pour plus de détails.", "Voir sur GitHub", "Plus tard", "Inklet est à jour", "Vous utilisez %@.", "Impossible de rechercher les mises à jour", "Vérifiez votre connexion Internet et réessayez.", "Réessayer", "Annuler"],
        "de": ["Nach Updates suchen…", "Updates werden gesucht…", "Ein Inklet-Update ist verfügbar", "Neueste: %@ (Build %d)", "Aktuell: %@", "Details finden Sie auf GitHub.", "Auf GitHub anzeigen", "Später", "Inklet ist auf dem neuesten Stand", "Sie verwenden %@.", "Updates konnten nicht überprüft werden", "Überprüfen Sie Ihre Internetverbindung und versuchen Sie es erneut.", "Erneut versuchen", "Abbrechen"],
        "pt": ["Buscar atualizações…", "Buscando atualizações…", "Há uma atualização do Inklet disponível", "Mais recente: %@ (compilação %d)", "Atual: %@", "Veja a versão no GitHub para obter detalhes.", "Ver no GitHub", "Mais tarde", "Inklet está atualizado", "Você está usando %@.", "Não foi possível buscar atualizações", "Verifique sua conexão com a internet e tente novamente.", "Tentar novamente", "Cancelar"],
        "it": ["Cerca aggiornamenti…", "Ricerca aggiornamenti…", "È disponibile un aggiornamento di Inklet", "Più recente: %@ (build %d)", "Attuale: %@", "Visualizza la release su GitHub per i dettagli.", "Visualizza su GitHub", "Più tardi", "Inklet è aggiornato", "Stai usando %@.", "Impossibile cercare aggiornamenti", "Controlla la connessione a Internet e riprova.", "Riprova", "Annulla"],
    ]

    func testUpdateCheckCopyMatchesEveryApprovedLocalizationTable() throws {
        let source = try localizationSource()
        let declaredTableIDs = try localizationTableIDs(in: source)
        XCTAssertEqual(Set(declaredTableIDs), Set(approvedTableIDs))
        XCTAssertEqual(declaredTableIDs.count, approvedTableIDs.count)
        XCTAssertEqual(Set(expectedValues.keys), Set(approvedTableIDs))

        for tableID in approvedTableIDs {
            let tableSource = try localizationTableSource(tableID, in: source)
            let values = try XCTUnwrap(expectedValues[tableID])
            XCTAssertEqual(values.count, updateCheckKeys.count)
            let entries = normalizedDictionaryEntries(in: tableSource)

            for (key, expectedValue) in zip(updateCheckKeys, values) {
                XCTAssertEqual(countDictionaryEntries(key, in: tableSource), 1, "Expected exactly one \(key) in \(tableID)")
                XCTAssertTrue(entries.contains(#""\#(key)": "\#(expectedValue)""#), "Unexpected \(key) value in \(tableID)")
            }
        }
    }

    func testUpdateCheckPlaceholderSignaturesAreIdenticalAndCorrect() throws {
        let source = try localizationSource()
        let expectedSignatures = Dictionary(uniqueKeysWithValues: updateCheckKeys.map { key in
            let signature: [String]
            switch key {
            case "update.available.latestVersion": signature = ["%@", "%d"]
            case "update.available.currentVersion", "update.upToDate.message": signature = ["%@"]
            default: signature = []
            }
            return (key, signature)
        })

        for tableID in approvedTableIDs {
            let entries = normalizedDictionaryEntries(in: try localizationTableSource(tableID, in: source))
            for key in updateCheckKeys {
                let entry = try XCTUnwrap(entries.first(where: { $0.hasPrefix(#""\#(key)":"#) }))
                XCTAssertEqual(formatPlaceholders(in: entry), expectedSignatures[key], "Unexpected placeholders for \(key) in \(tableID)")
            }
        }
    }

    func testUpdateCheckCopyResolvesWithoutFallbackForEveryInterfaceLanguage() throws {
        let savedLanguage = UserDefaults.standard.string(forKey: InkletPreferenceKeys.interfaceLanguage)
        defer {
            if let savedLanguage {
                UserDefaults.standard.set(savedLanguage, forKey: InkletPreferenceKeys.interfaceLanguage)
            } else {
                UserDefaults.standard.removeObject(forKey: InkletPreferenceKeys.interfaceLanguage)
            }
            NotificationCenter.default.post(name: .inkletLanguageDidChange, object: nil)
        }

        let languages: [String: InterfaceLanguage] = [
            "en": .english,
            "zhHans": .simplifiedChinese,
            "zhHant": .traditionalChinese,
            "ja": .japanese,
            "ko": .korean,
            "es": .spanish,
            "fr": .french,
            "de": .german,
            "pt": .portuguese,
            "it": .italian,
        ]
        XCTAssertEqual(Set(languages.keys), Set(approvedTableIDs))

        for tableID in approvedTableIDs {
            InkletLanguageStore.selectedLanguage = try XCTUnwrap(languages[tableID])
            let values = try XCTUnwrap(expectedValues[tableID])
            for (key, expectedValue) in zip(updateCheckKeys, values) {
                XCTAssertEqual(L10n.text(key), expectedValue, "Unexpected runtime \(key) value in \(tableID)")
            }
        }
    }

    func testUpdateCheckMenuLabelsUseUnicodeEllipsisInEveryTable() throws {
        let source = try localizationSource()
        for tableID in approvedTableIDs {
            let entries = normalizedDictionaryEntries(in: try localizationTableSource(tableID, in: source))
            for key in ["app.menu.checkForUpdates", "app.menu.checkingForUpdates"] {
                let entry = try XCTUnwrap(entries.first(where: { $0.hasPrefix(#""\#(key)":"#) }))
                XCTAssertTrue(entry.contains("…"), "Expected Unicode ellipsis in \(key) for \(tableID)")
                XCTAssertFalse(entry.contains("..."), "Expected no ASCII ellipsis in \(key) for \(tableID)")
            }
        }
    }

    private func localizationSource() throws -> String {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/InkletApp/InkletLocalization.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func localizationTableIDs(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"^[ \t]*private[ \t]+static[ \t]+let[ \t]+([A-Za-z_][A-Za-z0-9_]*):[ \t]*\[String:[ \t]*String\][ \t]*=[ \t]*\["#, options: .anchorsMatchLines)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    private func localizationTableSource(_ tableID: String, in source: String) throws -> String {
        let declaration = "    private static let \(tableID): [String: String] = ["
        let start = try XCTUnwrap(source.range(of: declaration)).upperBound
        let end = try XCTUnwrap(source.range(of: "\n    ]", range: start..<source.endIndex)).lowerBound
        return String(source[start..<end])
    }

    private func normalizedDictionaryEntries(in tableSource: String) -> [String] {
        tableSource.split(separator: "\n").map {
            let entry = $0.trimmingCharacters(in: .whitespaces)
            return entry.hasSuffix(",") ? String(entry.dropLast()) : entry
        }
    }

    private func countDictionaryEntries(_ key: String, in source: String) -> Int {
        source.components(separatedBy: #""\#(key)":"#).count - 1
    }

    private func formatPlaceholders(in entry: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:@|d)"#)
        let range = NSRange(entry.startIndex..<entry.endIndex, in: entry)
        return regex.matches(in: entry, range: range).compactMap {
            Range($0.range, in: entry).map { String(entry[$0]) }
        }
    }
}
