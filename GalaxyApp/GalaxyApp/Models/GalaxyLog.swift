import Foundation

/// Centralized logging for the Galaxy event system.
///
/// Writes to ~/.claude/galaxy/galaxy.log — a file we can always read
/// regardless of how the app was launched. macOS unified logging
/// (os.Logger, NSLog) does not persist logs from ad-hoc signed builds
/// unless explicitly configured, so file-based logging is the only
/// reliable option for non-Xcode workflows.
///
/// View live:  tail -f ~/.claude/galaxy/galaxy.log
/// Search:    grep "Galaxy/socket" ~/.claude/galaxy/galaxy.log
enum GalaxyLog {
    private static let logPath = NSHomeDirectory() + "/.claude/galaxy/galaxy.log"
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func socket(_ message: String) {
        write("[Galaxy/socket] \(message)")
    }

    static func events(_ message: String) {
        write("[Galaxy/events] \(message)")
    }

    static func enrichment(_ message: String) {
        write("[Galaxy/enrichment] \(message)")
    }

    static func circuit(_ message: String) {
        write("[Galaxy/circuit] \(message)")
    }

    static func js(_ channel: String, _ message: String) {
        write("[Galaxy/js/\(channel)] \(message)")
    }

    private static func write(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let dir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}
