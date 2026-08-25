import Foundation
import Galactic

/// Where each session's Files state is kept between launches.
///
/// **Its own file, not a field on `sessions.json`.** That file's `load()`
/// answers any decode failure by returning nil for the *whole* document and
/// quarantining it — which costs every session and every marker. A UI blob has
/// no business inside the one file whose corruption loses the session list.
/// `viewed-artifact-files.json` is the precedent and this follows it.
///
/// **Keyed by `Session.id`, not by `ledgerSessionId`** as the viewed-files store
/// is. A session has its UUID from creation; the ledger id arrives with
/// enrichment and is nil until then, which would leave a window where a set
/// could not be filed. The two stores disagreeing about their key is correct.
///
/// The shape written here is Galactic's `PersistedFileSet` — this type owns the
/// bytes and nothing about what is in them.
final class FilesStatePersistence: FileSetStore {
    static let shared = FilesStatePersistence()

    private struct Document: Codable {
        var version: Int
        /// Keyed by `Session.id.uuidString`.
        var sessions: [String: PersistedFileSet]
    }

    private static let currentVersion = 1
    private static let debounceInterval: TimeInterval = 1.0
    private static let maxDelay: TimeInterval = 3.0

    private let queue = DispatchQueue(
        label: "com.kellyredding.Galaxy.files-state"
    )
    private var cached: Document?
    private var writeTimer: Timer?
    private var firstDirtyAt: Date?

    private var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Galaxy", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("files-state.json")
    }

    private func document() -> Document {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(Document.self, from: data)
        else {
            let fresh = Document(version: Self.currentVersion, sessions: [:])
            cached = fresh
            return fresh
        }
        cached = decoded
        return decoded
    }

    // MARK: - FileSetStore

    func save(_ state: PersistedFileSet, forOwner ownerID: String) {
        var doc = document()
        // An empty set prunes rather than storing three empty fields, so a
        // session that opened Files once and closed everything does not keep a
        // row for the life of the file.
        if state.openPathRows.isEmpty && state.root.isEmpty {
            doc.sessions.removeValue(forKey: ownerID)
        } else {
            doc.sessions[ownerID] = state
        }
        cached = doc
        markDirty()
    }

    func load(forOwner ownerID: String) -> PersistedFileSet? {
        document().sessions[ownerID]
    }

    /// Drop a closed session's row, so the file does not grow forever.
    func discard(ownerID: String) {
        var doc = document()
        guard doc.sessions.removeValue(forKey: ownerID) != nil else { return }
        cached = doc
        markDirty()
    }

    // MARK: - Writing

    private func markDirty() {
        if firstDirtyAt == nil { firstDirtyAt = Date() }
        writeTimer?.invalidate()

        // Capped as well as debounced: a reader stepping through a strip emits a
        // change per keystroke, and a pure trailing debounce would never fire
        // while they kept moving.
        if let since = firstDirtyAt,
            Date().timeIntervalSince(since) >= Self.maxDelay
        {
            flushSync()
            return
        }
        writeTimer = Timer.scheduledTimer(
            withTimeInterval: Self.debounceInterval, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.flushSync() }
        }
    }

    /// Write now. Called from the debounce and at termination.
    ///
    /// **Registering this at quit is not optional and nothing enforces it** —
    /// see the comment beside the other stores in `GalaxyApp.swift`, which
    /// records that exactly this omission has already happened once.
    func flushSync() {
        writeTimer?.invalidate()
        writeTimer = nil
        firstDirtyAt = nil
        guard let doc = cached else { return }
        let url = fileURL
        queue.sync {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(doc) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
