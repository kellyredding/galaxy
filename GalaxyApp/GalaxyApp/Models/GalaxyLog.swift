import Foundation

/// Centralized logging for the Galaxy event system.
///
/// Writes to ~/.claude/galaxy/galaxy.log — a file we can always read
/// regardless of how the app was launched. macOS unified logging
/// (os.Logger, NSLog) does not persist logs from ad-hoc signed builds
/// unless explicitly configured, so file-based logging is the only
/// reliable option for non-Xcode workflows.
///
/// All writes run on a private serial queue that owns a persistent
/// file handle, so logging never blocks the caller (notably the main
/// thread, which routes socket events) and the file is opened once
/// rather than per line. The log rotates past `maxBytes`, keeping
/// `keepRotated` older segments (galaxy.log.1 … galaxy.log.N) — recent
/// history may therefore span the active file and galaxy.log.1.
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

    /// Serial queue that owns all file state below. Every write runs
    /// here — off the caller's thread — so the (non-thread-safe)
    /// `DateFormatter` and `FileHandle` are only ever touched serially.
    private static let queue = DispatchQueue(label: "galaxy.log")
    private static var handle: FileHandle? // queue-only
    private static var bytesWritten = 0 // queue-only

    /// Rotate once the active log passes this size; keep this many
    /// older segments.
    private static let maxBytes = 10 * 1024 * 1024
    private static let keepRotated = 3

    // MARK: - Public API

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

    /// Diagnostic logging for transient bug investigations.
    /// Tag categorizes the subsystem (e.g. "resume", "cmd",
    /// "switch", "active"). Remove call sites once the bug is
    /// resolved; the dbg method itself can stay.
    ///
    /// View live:  tail -f ~/.claude/galaxy/galaxy.log | grep dbg
    /// By tag:     grep "Galaxy/dbg/resume" ~/.claude/galaxy/galaxy.log
    static func dbg(_ tag: String, _ message: String) {
        write("[Galaxy/dbg/\(tag)] \(message)")
    }

    /// Flush pending writes to disk. Call from applicationWillTerminate
    /// so a clean shutdown does not drop the last few async lines.
    static func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    // MARK: - Writing

    private static func write(_ message: String) {
        // Capture the timestamp on the caller's thread so log order
        // reflects call time, then hand the line to the serial queue
        // for the actual file I/O.
        let now = Date()
        queue.async {
            appendOnQueue(now: now, message: message)
        }
    }

    /// Append one line. MUST run on `queue`.
    private static func appendOnQueue(now: Date, message: String) {
        let line = "[\(dateFormatter.string(from: now))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        guard let fh = openedHandle() else { return }

        do {
            try fh.write(contentsOf: data)
        } catch {
            // The handle went stale (file moved/deleted out from under
            // us). Drop it and retry once with a fresh handle.
            handle = nil
            guard let retry = openedHandle() else { return }
            try? retry.write(contentsOf: data)
        }

        bytesWritten += data.count
        if bytesWritten >= maxBytes { rotate() }
    }

    /// The active handle, opened (and the file created) once and left
    /// positioned at end of file. MUST run on `queue`.
    private static func openedHandle() -> FileHandle? {
        if let handle { return handle }

        let fm = FileManager.default
        let dir = (logPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil)
        }

        guard let fh = try? FileHandle(
            forWritingTo: URL(fileURLWithPath: logPath)
        ) else {
            return nil
        }
        bytesWritten = Int((try? fh.seekToEnd()) ?? 0)
        handle = fh
        return fh
    }

    /// Close the active log, shift galaxy.log.(N-1) → .N, move the
    /// active file to galaxy.log.1, and reopen a fresh log. MUST run
    /// on `queue`.
    private static func rotate() {
        let fm = FileManager.default
        try? handle?.close()
        handle = nil

        // Drop the oldest, shift the rest up by one, then archive the
        // active file as .1.
        try? fm.removeItem(atPath: "\(logPath).\(keepRotated)")
        var i = keepRotated - 1
        while i >= 1 {
            let src = "\(logPath).\(i)"
            if fm.fileExists(atPath: src) {
                try? fm.moveItem(atPath: src, toPath: "\(logPath).\(i + 1)")
            }
            i -= 1
        }
        try? fm.moveItem(atPath: logPath, toPath: "\(logPath).1")

        bytesWritten = 0
        _ = openedHandle() // reopen a fresh galaxy.log
    }
}
