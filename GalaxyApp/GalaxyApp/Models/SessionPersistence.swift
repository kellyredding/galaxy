import Foundation

// MARK: - Persisted Data Structures

/// Codable representation of a session for disk persistence.
/// Contains only the state that should survive app restart.
///
/// **Adding a field**: make it `Optional`. This decodes through the
/// synthesised initialiser, which reads an optional as `decodeIfPresent` and a
/// non-optional as required — so a required addition makes every
/// `sessions.json` written before it fail to decode. `load()` answers a decode
/// failure by returning nil for the *whole file*, so the cost is not the new
/// field defaulting: it is every session and every marker gone, with one line
/// in the log. The tolerant decoder on `PersistedSidebarState` below and the
/// `decodeIfPresent` note on `PersistedSessionMarker` above are the same rule
/// arrived at twice.
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

/// Codable representation of a session marker for disk persistence.
/// Lightweight — markers are pure metadata. `emoji` is optional for
/// backward compatibility with v3 files written before the emoji
/// feature shipped; old marker entries decode with `emoji = nil`
/// and resolve to empty string in the in-memory model. New writes
/// always include the field. No schema version bump needed —
/// `decodeIfPresent` is the migration.
struct PersistedSessionMarker: Codable {
    let id: UUID
    let name: String
    let emoji: String?
}

/// One element of the sidebar's ordered list. The `kind`
/// discriminator stabilizes the on-disk JSON shape regardless of
/// Swift compiler version (Swift's synthesized enum Codable
/// produces a less ergonomic shape).
///
/// On-disk JSON form:
///     { "kind": "session", "session": { ... PersistedSession ... } }
///     { "kind": "marker",  "marker":  { ... PersistedSessionMarker ... } }
enum PersistedSidebarItem: Codable {
    case session(PersistedSession)
    case marker(PersistedSessionMarker)

    private enum CodingKeys: String, CodingKey {
        case kind, session, marker
    }

    private enum Kind: String, Codable {
        case session, marker
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .session:
            self = .session(try c.decode(
                PersistedSession.self, forKey: .session
            ))
        case .marker:
            self = .marker(try c.decode(
                PersistedSessionMarker.self, forKey: .marker
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let s):
            try c.encode(Kind.session, forKey: .kind)
            try c.encode(s, forKey: .session)
        case .marker(let m):
            try c.encode(Kind.marker, forKey: .kind)
            try c.encode(m, forKey: .marker)
        }
    }
}

/// Top-level persisted state: version, active session, ordered
/// sidebar item list (array position = sidebar position), and
/// archived closed sessions for recovery.
///
/// v3 introduced `sidebarItems` to interleave sessions and markers
/// in a single ordered list. The decoder transparently upgrades v2
/// files (which had a flat `sessions` field) by wrapping each
/// session as `.session(...)`. The first write after a v2 read
/// produces a v3 file — no explicit migration step needed.
///
/// Old (v2) Galaxy builds cannot decode v3 files (missing required
/// `sessions` field). This is an accepted one-way migration.
struct PersistedSidebarState: Codable {
    let version: Int
    let activeSessionId: UUID?
    let sidebarItems: [PersistedSidebarItem]
    let closedSessions: [PersistedClosedSession]

    /// Computed convenience for read-only consumers.
    /// Filters sidebarItems down to sessions in order.
    var sessions: [PersistedSession] {
        sidebarItems.compactMap {
            if case .session(let s) = $0 { return s }
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, activeSessionId, sidebarItems,
             closedSessions, sessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        activeSessionId = try c.decodeIfPresent(
            UUID.self, forKey: .activeSessionId
        )
        closedSessions = try c.decodeIfPresent(
            [PersistedClosedSession].self,
            forKey: .closedSessions
        ) ?? []

        // v3: prefer sidebarItems if present.
        // v2 fallback: build sidebarItems from the legacy
        // sessions field. The next markDirty() rewrites in v3.
        if let items = try c.decodeIfPresent(
            [PersistedSidebarItem].self,
            forKey: .sidebarItems
        ) {
            sidebarItems = items
        } else {
            let legacy = try c.decodeIfPresent(
                [PersistedSession].self,
                forKey: .sessions
            ) ?? []
            sidebarItems = legacy.map { .session($0) }
        }
    }

    init(
        version: Int,
        activeSessionId: UUID?,
        sidebarItems: [PersistedSidebarItem],
        closedSessions: [PersistedClosedSession]
    ) {
        self.version = version
        self.activeSessionId = activeSessionId
        self.sidebarItems = sidebarItems
        self.closedSessions = closedSessions
    }

    /// Encode v3 only. Legacy `sessions` field is not written —
    /// old Galaxy builds will fail to decode (acceptable per
    /// migration plan).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(
            activeSessionId, forKey: .activeSessionId
        )
        try c.encode(sidebarItems, forKey: .sidebarItems)
        try c.encode(closedSessions, forKey: .closedSessions)
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
    ///
    /// A decode failure costs everything — every session and every marker —
    /// because there is one file and one decode. Nil then reads to the caller
    /// as "first launch", the sidebar comes up empty, and the next write
    /// replaces the file that could have been read by hand. So an unreadable
    /// file is moved aside rather than left in place to be overwritten: the
    /// launch is no better, but the loss stops being permanent.
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
            quarantineUnreadableFile()
            return nil
        }
    }

    /// Move an unreadable state file out of the way, keeping its contents.
    ///
    /// Best-effort by design: if this cannot rename the file, the launch
    /// proceeds exactly as it did before, which is the behaviour being
    /// improved on rather than one being relied upon.
    private func quarantineUnreadableFile() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let saved = fileURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(fileURL.lastPathComponent).corrupt-\(stamp)"
            )
        do {
            try FileManager.default.moveItem(at: fileURL, to: saved)
            GalaxyLog.events(
                "Kept the unreadable session file at \(saved.lastPathComponent)"
            )
        } catch {
            GalaxyLog.events(
                "Could not set aside the unreadable session file: \(error)"
            )
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
    /// Walks sidebarItems so sessions and markers are persisted in
    /// their interleaved sidebar order.
    private func captureState() -> PersistedSidebarState {
        let manager = SessionManager.shared
        let items: [PersistedSidebarItem] = manager.sidebarItems.map { item in
            switch item {
            case .session(let s):
                return .session(s.toPersistedState())
            case .marker(let m):
                return .marker(m.toPersistedState())
            }
        }
        return PersistedSidebarState(
            version: 3,
            activeSessionId: manager.activeSessionId,
            sidebarItems: items,
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
            let markerCount = state.sidebarItems.filter {
                if case .marker = $0 { return true }
                return false
            }.count
            GalaxyLog.events(
                "Session state persisted"
                + " (\(state.sessions.count) session(s)"
                + ", \(markerCount) marker(s)"
                + ", \(state.closedSessions.count) closed)"
            )
        } catch {
            GalaxyLog.events(
                "Failed to persist session state: \(error)"
            )
        }
    }
}
