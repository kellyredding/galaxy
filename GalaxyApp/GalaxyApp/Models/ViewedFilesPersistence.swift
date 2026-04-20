import Foundation

// MARK: - Persisted Data Structures

/// Top-level shape of `viewed-artifact-files.json`.
/// `sessions` is keyed by ledger session ID (as
/// String) → artifact number (as String) → ordered
/// list of file paths marked as viewed in that
/// artifact. JSON-friendly keys; the Swift API
/// accepts native types and translates.
struct PersistedViewedFiles: Codable {
    var version: Int
    var sessions: [String: [String: [String]]]
}

// MARK: - Persistence Manager

/// Manages per-ledger-session / per-artifact "viewed
/// file" state for diff reader artifacts. State lives
/// in the same directory as other Galaxy JSON state
/// files (window-state, sessions, settings) and uses
/// the same debounced-write pattern as
/// `WindowStatePersistence` so rapid checkbox toggles
/// don't thrash the disk.
///
/// All public methods must be called on the main
/// thread.
final class ViewedFilesPersistence {
    static let shared = ViewedFilesPersistence()

    /// Trailing debounce: write after 1s of no changes.
    private static let trailingDebounce: TimeInterval = 1.0

    /// Max delay cap: force write after 3s of
    /// sustained changes.
    private static let maxDelayCap: TimeInterval = 3.0

    private let fileURL: URL
    private var state: PersistedViewedFiles
    private var isDirty = false
    private var trailingTimer: Timer?
    private var maxCapTimer: Timer?

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let galaxyDir = appSupport.appendingPathComponent(
            "Galaxy",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: galaxyDir,
            withIntermediateDirectories: true
        )
        self.fileURL = galaxyDir.appendingPathComponent(
            "viewed-artifact-files.json"
        )
        self.state = Self.loadInitial(from: fileURL)
            ?? PersistedViewedFiles(
                version: 1, sessions: [:]
            )
    }

    // MARK: - Public API

    /// Snapshot of file paths currently marked viewed
    /// for the given session + artifact.
    func viewed(
        lsid: Int64, artifactNumber: Int32
    ) -> Set<String> {
        let lsidKey = String(lsid)
        let artifactKey = String(artifactNumber)
        if let paths
            = state.sessions[lsidKey]?[artifactKey]
        {
            return Set(paths)
        }
        return []
    }

    /// Mark (or unmark) a file as viewed. Writes are
    /// debounced; no synchronous disk I/O on toggle.
    func setViewed(
        lsid: Int64, artifactNumber: Int32,
        filePath: String, isViewed: Bool
    ) {
        let lsidKey = String(lsid)
        let artifactKey = String(artifactNumber)
        var artifactMap
            = state.sessions[lsidKey] ?? [:]
        var paths
            = artifactMap[artifactKey] ?? []

        if isViewed {
            if !paths.contains(filePath) {
                paths.append(filePath)
            }
        } else {
            paths.removeAll { $0 == filePath }
        }

        // Prune empty branches so the file shrinks
        // naturally when a session's last viewed file
        // is unchecked — keeps the JSON tidy without
        // needing a separate cleanup pass.
        if paths.isEmpty {
            artifactMap.removeValue(
                forKey: artifactKey
            )
        } else {
            artifactMap[artifactKey] = paths
        }
        if artifactMap.isEmpty {
            state.sessions.removeValue(
                forKey: lsidKey
            )
        } else {
            state.sessions[lsidKey] = artifactMap
        }

        isDirty = true
        scheduleWrite()
    }

    /// Flush pending state to disk asynchronously.
    func flush() {
        guard isDirty else { return }
        isDirty = false
        cancelTimers()
        let snapshot = state
        DispatchQueue.global(qos: .utility).async {
            [weak self] in
            self?.writeToDisk(snapshot)
        }
    }

    /// Flush synchronously — blocks until write
    /// completes. Used in applicationWillTerminate for
    /// clean quit.
    func flushSync() {
        guard isDirty else { return }
        isDirty = false
        cancelTimers()
        writeToDisk(state)
    }

    // MARK: - Private

    private func scheduleWrite() {
        trailingTimer?.invalidate()
        trailingTimer = Timer.scheduledTimer(
            withTimeInterval: Self.trailingDebounce,
            repeats: false
        ) { [weak self] _ in
            self?.flush()
        }

        if maxCapTimer == nil {
            maxCapTimer = Timer.scheduledTimer(
                withTimeInterval: Self.maxDelayCap,
                repeats: false
            ) { [weak self] _ in
                self?.flush()
            }
        }
    }

    private func cancelTimers() {
        trailingTimer?.invalidate()
        trailingTimer = nil
        maxCapTimer?.invalidate()
        maxCapTimer = nil
    }

    private func writeToDisk(
        _ snapshot: PersistedViewedFiles
    ) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted, .sortedKeys,
            ]
            let data = try encoder.encode(snapshot)
            try data.write(
                to: fileURL, options: .atomic
            )
        } catch {
            GalaxyLog.events(
                "ViewedFilesPersistence: "
                + "Failed to save: \(error)"
            )
        }
    }

    private static func loadInitial(
        from url: URL
    ) -> PersistedViewedFiles? {
        guard FileManager.default.fileExists(
            atPath: url.path
        ) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(
                PersistedViewedFiles.self,
                from: data
            )
        } catch {
            GalaxyLog.events(
                "ViewedFilesPersistence: "
                + "Failed to load: \(error)"
            )
            return nil
        }
    }
}
