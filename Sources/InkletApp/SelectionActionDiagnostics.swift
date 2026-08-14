import Foundation

@MainActor
enum SelectionActionDiagnostics {
    private static var lastCopySignature: String?
    private static var lastCopyLogTime: TimeInterval?
    private static var suppressedCopyEventCount = 0

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
        if signature == lastCopySignature,
           let lastCopyLogTime,
           time - lastCopyLogTime < 1 {
            suppressedCopyEventCount += 1
            return
        }

        if suppressedCopyEventCount > 0 {
            log("copy event suppressed=\(suppressedCopyEventCount)")
        }
        log("copy event \(signature)")
        lastCopySignature = signature
        lastCopyLogTime = time
        suppressedCopyEventCount = 0
    }

    static func resetCopyEventAggregation() {
        lastCopySignature = nil
        lastCopyLogTime = nil
        suppressedCopyEventCount = 0
    }
}
