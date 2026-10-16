import Foundation
import os

/// Output goes to stdout (when run from a terminal), the unified log, and
/// ~/Library/Logs/Tacet.log (when launched with `open`).
///
/// - `write`: general events, with counts rather than app names or paths.
/// - `debug`: details (bundle IDs of tracked apps, the bundle path). Only
///   with `defaults write app.gettacet.Tacet debugLogging -bool true` or the
///   `--debug` argument, and private in the unified log (review §4.3): it is
///   an inventory of the user's menu bar apps.
/// - The file is rotated at launch once it passes 1 MB: the old one becomes
///   Tacet.old.log, replacing the previous one (review §1.1).
enum Log {
    private static let logger = Logger(subsystem: "app.gettacet.Tacet", category: "app")
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Tacet.log")
    static let isDebug = CommandLine.arguments.contains("--debug")
        || UserDefaults.standard.bool(forKey: "debugLogging")
    private static let maxSize = 1_000_000

    private static let rotated: Void = {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > maxSize else { return }
        let old = fileURL.deletingLastPathComponent().appendingPathComponent("Tacet.old.log")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: fileURL, to: old)
    }()

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    static func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
        emit(message)
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard isDebug else { return }
        let text = message()
        logger.debug("\(text, privacy: .private)")
        emit("[debug] " + text)
    }

    private static func emit(_ message: String) {
        _ = rotated
        print(message)
        fflush(stdout)
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
