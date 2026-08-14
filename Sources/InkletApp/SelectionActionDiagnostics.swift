import Foundation
import InkletCore

@MainActor
enum SelectionActionDiagnostics {
    private static var eventRateLimiter = SelectionActionDiagnosticRateLimiter()

    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InkletSelectionActions.log")
        guard let data = line.data(using: .utf8) else {
            return
        }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func logCopyEvent(
        foregroundApp: String,
        keyCode: UInt16,
        modifiers: UInt,
        isRepeat: Bool,
        sourcePID: Int64,
        marker: Int64,
        decision: String,
        at time: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) {
        let signature = "app=\(foregroundApp) keyCode=\(keyCode) modifiers=\(modifiers) "
            + "repeat=\(isRepeat) sourcePID=\(sourcePID) marker=\(marker) decision=\(decision)"
        logRateLimited("copy event \(signature)", at: time)
    }

    static func logRateLimited(
        _ message: String,
        at time: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) {
        switch eventRateLimiter.record(signature: message, at: time) {
        case .suppress:
            return
        case .log(let suppressedCount):
            if suppressedCount > 0 {
                log("selection event suppressed=\(suppressedCount)")
            }
            log(message)
        }
    }

    static func resetCopyEventAggregation() {
        eventRateLimiter.reset()
    }
}
