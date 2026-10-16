import Foundation
import os

/// Debug output goes to stdout (when run from a terminal), the unified log,
/// and ~/Library/Logs/Tacet.log (when launched with `open`).
enum Log {
    private static let logger = Logger(subsystem: "app.gettacet.Tacet", category: "app")
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Tacet.log")

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    static func write(_ message: String) {
        print(message)
        fflush(stdout)
        logger.info("\(message, privacy: .public)")
        let line = "[\(timestamp())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }
}
