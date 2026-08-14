import Foundation
import InkletCore

@MainActor
enum SelectionActionDiagnostics {
    private static var fileURL: URL?
    private static var eventRateLimiter = SelectionActionDiagnosticRateLimiter()

    static func configure(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func log(_ message: String) {
        guard let url = fileURL else {
            return
        }

        let line = "\(Date()) \(message)\n"
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

    static func resetEventAggregation() {
        eventRateLimiter.reset()
    }
}
