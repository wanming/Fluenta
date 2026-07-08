import Foundation

public enum SelectionBrowserTextReaderError: Error, Equatable, Sendable {
    case executionFailed(String)
}

@MainActor
public struct SelectionBrowserTextReader: Sendable {
    public typealias AppleScriptRunner = @MainActor @Sendable (String) -> Result<String, SelectionBrowserTextReaderError>

    private let appleScriptRunner: AppleScriptRunner

    public init(appleScriptRunner: @escaping AppleScriptRunner = Self.systemRunAppleScript) {
        self.appleScriptRunner = appleScriptRunner
    }

    public init(_ appleScriptRunner: @escaping AppleScriptRunner) {
        self.appleScriptRunner = appleScriptRunner
    }

    public func readSelectedText(bundleIdentifier: String?) async -> SelectedTextReadResult {
        guard let browser = SupportedBrowser(bundleIdentifier: bundleIdentifier) else {
            return .unsupported
        }

        switch appleScriptRunner(browser.selectedTextAppleScript) {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .emptySelection : .success(trimmed)
        case .failure(let error):
            return .failed("Browser selection read failed: \(error.localizedDescription)")
        }
    }

    public static func systemRunAppleScript(_ source: String) -> Result<String, SelectionBrowserTextReaderError> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(.executionFailed("Could not create AppleScript."))
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return .failure(.executionFailed("\(errorInfo)"))
        }

        return .success(result.stringValue ?? "")
    }
}

private enum SupportedBrowser: String, CaseIterable {
    case safari = "com.apple.Safari"
    case chrome = "com.google.Chrome"
    case edge = "com.microsoft.edgemac"

    init?(bundleIdentifier: String?) {
        guard let bundleIdentifier else {
            return nil
        }
        self.init(rawValue: bundleIdentifier)
    }

    var selectedTextAppleScript: String {
        let javascript = Self.appleScriptStringLiteral("window.getSelection().toString();")
        switch self {
        case .safari:
            return """
            tell application id "\(rawValue)"
                do JavaScript "\(javascript)" in document 1
            end tell
            """
        case .chrome, .edge:
            return """
            tell application id "\(rawValue)"
                tell active tab of front window
                    execute javascript "\(javascript)"
                end tell
            end tell
            """
        }
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension SelectionBrowserTextReaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return message
        }
    }
}
