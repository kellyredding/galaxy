import Foundation

// MARK: - Persisted Data Structures

/// Codable representation of a session for disk persistence.
/// Contains only the state that should survive app restart.
struct PersistedSession: Codable {
    // Identity (unrecoverable without persistence)
    let id: UUID
    let sessionRef: String
    let givenName: String?
    let claudeSessionId: String
    let workingDirectory: String
    let personaName: String?
    let isVibe: Bool
    let createdAt: Date

    // Ledger enrichment (recoverable from ledger, but provides
    // immediate sidebar content on restore before sync completes)
    let ledgerSessionId: Int64?
    let ledgerSessionIdentifiers: [String]?
    let ledgerSuggestedName: String?
    let ledgerCwd: String?
    let ledgerProjectDir: String?
    let ledgerGitBranch: String?
    let ledgerModelDisplayName: String?
    let ledgerContextPercentage: Double?
    let ledgerTokensUsed: Int?
    let ledgerTokensMax: Int?
    let ledgerCostUsd: Double?
    let ledgerLinesAdded: Int?
    let ledgerLinesRemoved: Int?
    let ledgerStartedAt: String?
    let ledgerUpdatedAt: String?
}

/// A dismissed session preserved for potential restoration.
/// Wraps PersistedSession with the timestamp of dismissal.
struct PersistedClosedSession: Codable {
    let session: PersistedSession
    let closedAt: Date
}

/// Top-level persisted state: version, active session, ordered
/// session list (array position = sidebar position), and archived
/// closed sessions for recovery.
struct PersistedSidebarState: Codable {
    let version: Int
    let activeSessionId: UUID?
    let sessions: [PersistedSession]
    let closedSessions: [PersistedClosedSession]

    /// Coding keys with default for closedSessions (v1 migration)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        activeSessionId = try container.decodeIfPresent(UUID.self, forKey: .activeSessionId)
        sessions = try container.decode([PersistedSession].self, forKey: .sessions)
        closedSessions = try container.decodeIfPresent([PersistedClosedSession].self, forKey: .closedSessions) ?? []
    }

    init(version: Int, activeSessionId: UUID?, sessions: [PersistedSession], closedSessions: [PersistedClosedSession]) {
        self.version = version
        self.activeSessionId = activeSessionId
        self.sessions = sessions
        self.closedSessions = closedSessions
    }
}

// MARK: - Persistence Manager

/// Manages debounced persistence of session state to disk.
/// All public methods must be called on the main thread.
final class SessionPersistence {
    static let shared = SessionPersistence()

    /// Trailing debounce: write after 1s of no changes.
    private static let trailingDebounce: TimeInterval = 1.0

    /// Max delay cap: force write after 3s of sustained changes.
    private static let maxDelayCap: TimeInterval = 3.0

    private let fileURL: URL
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
        self.fileURL = galaxyDir.appendingPathComponent("sessions.json")
    }

    // MARK: - Public API

    /// Mark session state as dirty. Starts/resets the debounce
    /// timers. Called from any code that mutates persisted state.
    func markDirty() {
        isDirty = true

        // Reset trailing timer (1s after last change)
        trailingTimer?.invalidate()
        trailingTimer = Timer.scheduledTimer(
            withTimeInterval: Self.trailingDebounce,
            repeats: false
        ) { [weak self] _ in
            self?.flush()
        }

        // Start max cap timer if not already running (3s ceiling)
        if maxCapTimer == nil {
            maxCapTimer = Timer.scheduledTimer(
                withTimeInterval: Self.maxDelayCap,
                repeats: false
            ) { [weak self] _ in
                self?.flush()
            }
        }
    }

    /// Flush pending state to disk asynchronously.
    /// Snapshots on main thread, writes on background queue.
    func flush() {
        guard isDirty else { return }
        isDirty = false
        cancelTimers()

        let state = captureState()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.writeToDisk(state)
        }
    }

    /// Flush synchronously — blocks until write completes.
    /// Used in applicationWillTerminate for clean quit.
    func flushSync() {
        guard isDirty else { return }
        isDirty = false
        cancelTimers()

        let state = captureState()
        writeToDisk(state)
    }

    /// Load persisted state from disk. Returns nil on first
    /// launch, missing file, or corrupt data.
    func load() -> PersistedSidebarState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(
                PersistedSidebarState.self,
                from: data
            )
        } catch {
            GalaxyLog.events(
                "Failed to load persisted sessions: \(error)"
            )
            return nil
        }
    }

    // MARK: - Private

    private func cancelTimers() {
        trailingTimer?.invalidate()
        trailingTimer = nil
        maxCapTimer?.invalidate()
        maxCapTimer = nil
    }

    /// Snapshot current session state on the main thread.
    private func captureState() -> PersistedSidebarState {
        let manager = SessionManager.shared
        return PersistedSidebarState(
            version: 2,
            activeSessionId: manager.activeSessionId,
            sessions: manager.sessions.map { $0.toPersistedState() },
            closedSessions: manager.closedSessions
        )
    }

    /// Write state to disk atomically (temp file + rename).
    private func writeToDisk(_ state: PersistedSidebarState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
            GalaxyLog.events(
                "Session state persisted"
                + " (\(state.sessions.count) session(s)"
                + ", \(state.closedSessions.count) closed)"
            )
        } catch {
            GalaxyLog.events(
                "Failed to persist session state: \(error)"
            )
        }
    }
}
