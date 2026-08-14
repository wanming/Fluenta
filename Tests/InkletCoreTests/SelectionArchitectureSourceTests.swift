import XCTest

final class SelectionArchitectureSourceTests: XCTestCase {
    func testProductionSwiftSourcesDoNotUseBrowserSpecificSelectionAutomation() throws {
        let forbiddenTokens = [
            "SelectionBrowserTextReader",
            "com.google.Chrome",
            "com.microsoft.edgemac",
            "com.apple.Safari",
            "tell application id"
        ]
        var violations: [String] = []

        for sourceFile in try productionSwiftSources() {
            for token in forbiddenTokens where sourceFile.source.contains(token) {
                violations.append("\(sourceFile.relativePath): contains \(token)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Browser-specific selection automation remains:\n\(violations.sorted().joined(separator: "\n"))"
        )
    }

    func testAppleScriptIsLimitedToUntargetedAlertVolumeOperations() throws {
        let sourceFiles = try productionSwiftSources()
        let allowedRelativePath = "Sources/InkletCore/SelectionClipboardReader.swift"
        let filesContainingAppleScript = sourceFiles
            .filter { $0.source.contains("NSAppleScript") }
            .map(\.relativePath)

        XCTAssertEqual(
            filesContainingAppleScript,
            [allowedRelativePath],
            "NSAppleScript may appear only in the clipboard selection reader."
        )

        let clipboardSource = try XCTUnwrap(
            sourceFiles.first { $0.relativePath == allowedRelativePath }?.source
        )
        let currentVolumeBlock = try sourceScope(
            startingAt: "private static func currentAlertVolume()",
            endingBefore: "private static func setAlertVolume",
            in: clipboardSource
        )
        let setVolumeBlock = try sourceScope(
            startingAt: "private static func setAlertVolume",
            endingBefore: "private static func findCopyMenuItem",
            in: clipboardSource
        )
        let getVolumeConstruction = #"NSAppleScript(source: "return alert volume of (get volume settings)")"#
        let setVolumeConstruction = #"NSAppleScript(source: "set volume alert volume \(clampedVolume)")"#

        XCTAssertEqual(occurrenceCount(of: "NSAppleScript", in: clipboardSource), 2)
        XCTAssertEqual(occurrenceCount(of: "NSAppleScript(source:", in: clipboardSource), 2)
        XCTAssertEqual(occurrenceCount(of: "executeAndReturnError(&errorInfo)", in: clipboardSource), 2)

        XCTAssertEqual(occurrenceCount(of: "NSAppleScript", in: currentVolumeBlock), 1)
        XCTAssertEqual(occurrenceCount(of: getVolumeConstruction, in: currentVolumeBlock), 1)
        XCTAssertEqual(
            occurrenceCount(of: "script?.executeAndReturnError(&errorInfo).stringValue", in: currentVolumeBlock),
            1
        )

        XCTAssertEqual(occurrenceCount(of: "NSAppleScript", in: setVolumeBlock), 1)
        XCTAssertEqual(occurrenceCount(of: setVolumeConstruction, in: setVolumeBlock), 1)
        XCTAssertEqual(
            occurrenceCount(of: "script?.executeAndReturnError(&errorInfo)", in: setVolumeBlock),
            1
        )

        let forbiddenTargetingTokens = [
            "tell application",
            "using terms from application",
            "application id",
            "bundle identifier"
        ]
        for token in forbiddenTargetingTokens {
            XCTAssertFalse(
                clipboardSource.localizedCaseInsensitiveContains(token),
                "Clipboard alert-volume scripts must not target an application: \(token)"
            )
        }
    }

    private func productionSwiftSources() throws -> [ProductionSourceFile] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        let sourcesRoot = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourcesRoot,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
        )
        var sourceFiles: [ProductionSourceFile] = []

        for case let sourceURL as URL in enumerator where sourceURL.pathExtension == "swift" {
            let resourceValues = try sourceURL.resourceValues(forKeys: resourceKeys)
            guard resourceValues.isRegularFile == true else {
                continue
            }
            sourceFiles.append(ProductionSourceFile(
                relativePath: sourceURL.path.replacingOccurrences(
                    of: packageRoot.path + "/",
                    with: ""
                ),
                source: try String(contentsOf: sourceURL, encoding: .utf8)
            ))
        }

        return sourceFiles.sorted { $0.relativePath < $1.relativePath }
    }

    private func sourceScope(
        startingAt startToken: String,
        endingBefore endToken: String,
        in source: String
    ) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: startToken))
        let endRange = try XCTUnwrap(source.range(
            of: endToken,
            range: startRange.upperBound..<source.endIndex
        ))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func occurrenceCount(of token: String, in source: String) -> Int {
        source.components(separatedBy: token).count - 1
    }
}

private struct ProductionSourceFile {
    let relativePath: String
    let source: String
}
