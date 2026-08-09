import Foundation
import InkletCore

enum SelectionActionDiagnostics {
    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let url = InkletStoragePaths.currentOrLocalDevelopment().selectionDiagnosticsFileURL
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
}
