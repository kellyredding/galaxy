import Foundation
import AppKit
import SwiftUI
import SwiftTerm
import Combine

enum ListNavAction {
    case up, down, activate
}

class SessionManager: ObservableObject {
    // Singleton instance for access from AppDelegate
    static let shared = SessionManager()

    @Published var sessions: [Session] = []
    @Published var activeSessionId: UUID? {
        didSet {
            guard activeSessionId != oldValue else { return }

            // Suppress focus reporting (mode 1004) on the two terminals
            // involved in this switch. Without this, makeFirstResponder
            // triggers becomeFirstResponder/resignFirstResponder which
            // send focus in/out escape sequences to the PTY — Claude Code
            // responds to those, producing output that triggers false
            // busy/idle state transitions (pulsing status dot, unread
            // indicators, notifications).
            if let oldId = oldValue,
               let oldSession = sessions.first(where: { $0.id == oldId })
            {
                oldSession.terminalView?.suppressFocusEvents = true
            }
            if let newId = activeSessionId,
               let newSession = sessions.first(where: { $0.id == newId })
            {
                newSession.terminalView?.suppressFocusEvents = true
            }
        }
    }

    // Track whether the main window is focused (for bell indicator logic)
    @Published var isWindowFocused: Bool = true

    // Sidebar visibility — persisted in AppSettings, accessed via
    // SettingsManager. Computed property delegates read/write so
    // existing view code (ContentView, MainMenu) works unchanged.
    var isSidebarVisible: Bool {
        get { SettingsManager.shared.settings.isSidebarVisible }
        set { SettingsManager.shared.settings.isSidebarVisible = newValue }
    }

    // Active tab in the views area — driven by the active session.
    // Not persisted — always starts on Terminal at launch.
    @Published var activeTab: SessionTab = .terminal

    // Active subtab within Ledger view — driven by the active session.
    // Not persisted — always starts on Last Activity at launch.
    @Published var activeLedgerSubTab: LedgerSubTab = .identifiers

    /// Snapshot number to auto-open when switching to snapshots tab.
    /// Set by EventCoordinator on snapshot.created, cleared by SnapshotsView after opening.
    @Published var pendingSnapshotNumber: Int32? = nil

    /// Set by EventCoordinator when annotation/review events arrive.
    /// SnapshotsView observes this to refresh review button visibility.
    @Published var pendingReviewCheck: Int64? = nil

    /// Set by EventCoordinator on agent lifecycle events.
    /// AgentsView observes this to refresh its data.
    /// Tuple of (sessionId, timestamp) for targeted refresh.
    @Published var agentRefreshTrigger:
        (UUID, Date)? = nil

    /// List navigation action bridged from menu shortcuts.
    /// Set by MenuActions, consumed by the active list view's onChange handler.
    @Published var listNavAction: ListNavAction? = nil

    /// Whether the snapshot reader is open (used by views that need to know).
    @Published var isSnapshotReaderOpen: Bool = false

    /// Whether the artifact reader is open (used by views that need to know).
    @Published var isArtifactReaderOpen: Bool = false

    /// Artifact number to auto-open/show when switching to artifacts tab.
    /// Set by EventCoordinator on artifact.show, cleared by ArtifactsView after opening.
    @Published var pendingArtifactShow: Int32? = nil

    /// Per-session queued artifact/snapshot "show" intents for
    /// events that arrived while that session wasn't active.
    /// Drained by `switchTo(sessionId:)` after the view state
    /// is restored — the session's `lastActiveTab` is also
    /// overridden to the appropriate tab on queue so the
    /// existing tab-restore path lands the user on the right
    /// tab automatically. Kept private because callers go
    /// through `queueArtifactShow` / `queueSnapshotShow`.
    ///
    /// **In-memory only — not persisted.** If Galaxy.app
    /// restarts (or crashes) between the event arriving and
    /// the user switching back to the queued session, the
    /// intent is lost — and the tab override is lost too
    /// (Session's `lastActiveTab` is per-runtime state, not
    /// in `toPersistedState`). Explicit trade-off against
    /// adding disk I/O and persistence-schema complexity for
    /// a transient UI cue that only matters in the narrow
    /// window between a CLI `show` firing and the user
    /// switching back.
    private var pendingArtifactBySession:
        [UUID: Int32] = [:]
    private var pendingSnapshotBySession:
        [UUID: Int32] = [:]

    /// Called when a session is removed from the session list.
    /// Used by EventCoordinator to clean up cached ledger_session_id mappings.
    var onSessionClosed: ((UUID) -> Void)?

    // Track if active session can be resumed (for menu updates)
    @Published var activeSessionCanResume: Bool = false

    /// Archived closed sessions available for restoration.
    /// Most recently closed at index 0. Persisted to sessions.json.
    @Published var closedSessions: [PersistedClosedSession] = []

    /// Tracks last auto-clear time per session to prevent re-triggering
    /// before enrichment updates with fresh post-clear context percentage.
    private var lastAutoClearTime: [UUID: Date] = [:]

    /// Pending idle notification timers per session. Scheduled when a session
    /// goes idle and passes the minimum busy duration filter. Canceled if the
    /// session goes busy again before the timer fires (minimum idle duration).
    private var pendingIdleNotificationTimers: [UUID: Timer] = [:]

    /// Per-session Combine subscription to
    /// `session.$terminalView`. Fires `wireSessionCallbacks` every
    /// time the terminal view transitions to non-nil (session
    /// start, resume). Torn down when the session is removed.
    private var terminalViewSubs: [UUID: AnyCancellable] = [:]

    /// Minimum seconds between auto-clears for the same session.
    private static let autoClearCooldown: TimeInterval = 30

    /// Maximum number of closed sessions to retain in the archive.
    private static let closedSessionRetentionLimit = 500

    // Path to claude binary - detected at init
    let claudePath: String

    // Path to claude-persona binary - detected at init, nil if not installed
    let claudePersonaPath: String?

    var activeSession: Session? {
        sessions.first { $0.id == activeSessionId }
    }

    /// Update the activeSessionCanResume flag based on current state
    private func updateActiveSessionCanResume() {
        let canResume = activeSession?.hasExited ?? false
        if activeSessionCanResume != canResume {
            activeSessionCanResume = canResume
        }
    }

    init() {
        // Detect binary paths
        self.claudePath = SessionManager.findBinaryPath(
            name: "claude",
            searchPaths: [
                "\(NSHomeDirectory())/.local/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
            ],
            fallback: "\(NSHomeDirectory())/.local/bin/claude"
        )
        self.claudePersonaPath = SessionManager.findBinaryPath(name: "claude-persona")

        // Restore persisted sessions (all as stopped)
        if let persisted = SessionPersistence.shared.load() {
            for state in persisted.sessions {
                let session = Session(restoring: state)
                sessions.append(session)
                // Observe terminalView lifecycle even for stopped
                // sessions — when the user resumes one,
                // ensureTerminalView() fires the subscription and
                // callbacks wire automatically. Restored sessions
                // start with terminalView == nil, so the immediate
                // sink fire is a no-op.
                observeTerminalViewLifecycle(for: session)
            }
            if let activeId = persisted.activeSessionId {
                activeSessionId = activeId
            }
            // Restore closed session archive
            closedSessions = persisted.closedSessions
            NSLog(
                "SessionManager: Restored %d session(s) and %d closed session(s) from disk",
                sessions.count,
                closedSessions.count
            )
        }
    }

    /// Find a binary by checking common paths, then falling back to `which`.
    /// Returns the resolved path, or `fallback` if provided and nothing found, or nil.
    private static func findBinaryPath(
        name: String,
        searchPaths: [String]? = nil,
        fallback: String? = nil
    ) -> String? {
        // Check explicit search paths first
        let paths = searchPaths ?? [
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: which command
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                return output
            }
        } catch {
            // Ignore errors
        }

        return fallback
    }

    // Non-optional overload for claude (always returns a path)
    private static func findBinaryPath(
        name: String,
        searchPaths: [String],
        fallback: String
    ) -> String {
        return findBinaryPath(name: name, searchPaths: searchPaths, fallback: fallback as String?) ?? fallback
    }

    @discardableResult
    func createSession(
        workingDirectory: String? = nil,
        personaName: String? = nil,
        givenName: String? = nil,
        isVibe: Bool = false,
        resumeSessionId: String? = nil
    ) -> Session {
        let directory = workingDirectory ?? NSHomeDirectory()
        let sessionId = SessionIDGenerator.generate()

        // Parse resume UUID if provided
        let resumeUUID: UUID? = resumeSessionId.flatMap { UUID(uuidString: $0) }

        let session = Session(
            workingDirectory: directory,
            sessionRef: sessionId,
            personaName: personaName,
            isVibe: isVibe,
            resumeSessionId: resumeUUID
        )

        // Set optional user-assigned name (Galaxy-only, not passed to Claude)
        session.givenName = givenName

        // Determine the executable path: claude-persona for persona sessions, claude for vanilla
        let executablePath: String
        if personaName != nil, let cpPath = claudePersonaPath {
            executablePath = cpPath
        } else {
            executablePath = claudePath
        }

        // Observe the session's terminalView lifecycle. Fires
        // immediately with the current (just-created-in-init)
        // view, which triggers wireSessionCallbacks → sets up
        // the bell, processDelegate, onDataReceived, content
        // monitor, and session-level turn callbacks. The same
        // subscription handles future recreations on resume.
        observeTerminalViewLifecycle(for: session)

        // Determine if this is a resume (resumeSessionId provided means URL had resume param)
        let isResume = resumeSessionId != nil

        // Start the process
        session.startProcess(executablePath: executablePath, resume: isResume)

        sessions.append(session)
        saveViewState()
        activeSessionId = session.id
        activeTab = .terminal
        activeLedgerSubTab = .identifiers
        SessionPersistence.shared.markDirty()

        return session
    }

    func handleSessionExited(sessionId: UUID) {
        NSLog("SessionManager: handleSessionExited called for %@", sessionId.uuidString)

        // Update menu state and persist
        DispatchQueue.main.async {
            self.updateActiveSessionCanResume()
            SessionPersistence.shared.markDirty()

            // Session Exited Unexpectedly notification
            if SettingsManager.shared.settings
                .notifySessionExitedUnexpectedly
            {
                if let session = self.sessions.first(
                    where: { $0.id == sessionId }
                ),
                   !session.userInitiatedStop,
                   let exitCode = session.exitCode,
                   exitCode != 0
                {
                    NotificationService.shared
                        .notifySessionExitedUnexpectedly(
                            sessionId: sessionId,
                            displayName: session.displayName,
                            exitCode: exitCode
                        )
                }
            }
        }

        NSLog("SessionManager: Session marked as exited, keeping in sidebar")
    }

    // MARK: - Stop Warning Reasons

    /// Reasons a session might need confirmation before stopping.
    /// Priority order: unsavedScrollback > inTurn > runningAgents.
    enum StopWarningReason {
        case unsavedScrollback
        case inTurn
        case runningAgents(count: Int)

        var message: String {
            switch self {
            case .unsavedScrollback:
                return "Stop session with unsaved "
                    + "scrollback notes?"
            case .inTurn:
                return "Stop session while Claude "
                    + "is responding?"
            case .runningAgents:
                return "Stop session with running "
                    + "agents?"
            }
        }

        var detail: String {
            switch self {
            case .unsavedScrollback:
                return "Unsaved notes will be lost "
                    + "when the session stops."
            case .inTurn:
                return "Claude's current response "
                    + "will be interrupted."
            case .runningAgents(let count):
                return "\(count) background "
                    + "agent(s) will be "
                    + "terminated."
            }
        }
    }

    /// Check if a session needs confirmation before stopping.
    /// Calls back with the highest-priority reason, or nil
    /// if safe to stop without confirmation.
    func stopWarningReason(
        for session: Session,
        completion: @escaping (StopWarningReason?) -> Void
    ) {
        guard !session.hasExited else {
            completion(nil)
            return
        }

        let isBusy = session.isInTurn
        let agentCount = session.runningAgentCount

        // Stop-session only consults the SESSION pane's
        // scrollback. Shell-pane notes are explicitly
        // out of scope here — the shell process survives
        // session stop, so its notes aren't lost.
        session.checkAnyScrollbackUnsavedWork(
            kinds: [.session]
        ) { hasWork in
            if hasWork {
                completion(.unsavedScrollback)
            } else if isBusy {
                completion(.inTurn)
            } else if agentCount > 0 {
                completion(
                    .runningAgents(count: agentCount)
                )
            } else {
                completion(nil)
            }
        }
    }

    /// Check all sessions — live AND stopped — for quit
    /// warnings. Differs from `stopWarningReason` in two
    /// ways: it also covers stopped sessions (their
    /// shell pane may still be open with notes that quit
    /// would destroy), and live sessions consult both
    /// their session-pane and shell-pane scrollback
    /// (quit kills both).
    func quitWarnings(
        completion: @escaping (
            [(Session, StopWarningReason)]
        ) -> Void
    ) {
        guard !sessions.isEmpty else {
            completion([])
            return
        }

        let group = DispatchGroup()
        var warnings: [(Session, StopWarningReason)] = []
        let lock = NSLock()

        for session in sessions {
            // Stopped sessions: only the shell pane can
            // still hold unsaved notes (session pane is
            // gone). Live sessions: both panes apply.
            let kinds: Set<Session.ScrollbackPaneKind> =
                session.hasExited
                    ? [.shell]
                    : [.session, .shell]

            group.enter()
            session.checkAnyScrollbackUnsavedWork(
                kinds: kinds
            ) { hasScrollbackWork in
                if hasScrollbackWork {
                    lock.lock()
                    warnings.append(
                        (session, .unsavedScrollback)
                    )
                    lock.unlock()
                    group.leave()
                    return
                }
                // No scrollback work — for live sessions,
                // also surface in-turn / running-agent
                // warnings (those don't apply to stopped
                // sessions, which have no process left to
                // be busy or run agents).
                if !session.hasExited {
                    if session.isInTurn {
                        lock.lock()
                        warnings.append(
                            (session, .inTurn)
                        )
                        lock.unlock()
                    } else if session.runningAgentCount
                        > 0 {
                        lock.lock()
                        warnings.append(
                            (
                                session,
                                .runningAgents(
                                    count: session
                                        .runningAgentCount
                                )
                            )
                        )
                        lock.unlock()
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(warnings)
        }
    }

    func confirmAndStopSession(sessionId: UUID) {
        guard let session = sessions.first(
            where: { $0.id == sessionId }
        ) else { return }

        let proceed: () -> Void = { [weak self] in
            self?.stopSession(sessionId: sessionId)
        }

        stopWarningReason(for: session) { reason in
            guard let reason = reason else {
                proceed()
                return
            }
            guard let window = NSApp.keyWindow
            else { return }
            SheetAlert.confirm(
                in: window,
                message: reason.message,
                detail: reason.detail,
                confirm: "Stop",
                onConfirm: proceed
            )
        }
    }

    func stopSession(sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }) else {
            NSLog("SessionManager: Cannot stop - session not found")
            return
        }

        guard !session.hasExited else {
            NSLog("SessionManager: Cannot stop - session already stopped")
            return
        }

        NSLog("SessionManager: Stopping session %@", session.sessionRef)

        // Mark as user-initiated so handleSessionExited doesn't fire
        // the "exited unexpectedly" notification for intentional stops.
        session.userInitiatedStop = true

        // Terminate the process using our tracked PID (sends SIGTERM)
        session.terminateProcess()

        // Switch to terminal so the user sees the stopped state,
        // but only if this is the currently selected session.
        if sessionId == activeSessionId {
            activeTab = .terminal
        }
    }

    func resumeSession(sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }) else {
            NSLog("SessionManager: Cannot resume - session not found")
            return
        }

        guard session.hasExited else {
            NSLog("SessionManager: Cannot resume - session is still running")
            return
        }

        // Check if working directory still exists
        if !FileManager.default.fileExists(atPath: session.workingDirectory) {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Cannot Resume Session"
                alert.informativeText = """
                    The working directory for this session no longer \
                    exists:

                    \(session.workingDirectory)

                    You can close this session or copy the resume \
                    command to restart it manually.
                    """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }

        // Check if Claude has this session saved on disk
        let canResume = claudeSessionExists(sessionId: session.claudeSessionId, workingDirectory: session.workingDirectory)

        if canResume {
            NSLog("SessionManager: Resuming session %@ (found in Claude storage)", session.sessionRef)
        } else {
            NSLog("SessionManager: Session %@ not found in Claude storage, starting fresh", session.sessionRef)
        }

        // Save outgoing session's view state and switch to terminal
        // so the user sees the resumed session. Restore the incoming
        // session's ledger subtab so it's correct if they visit ledger.
        saveViewState()
        activeTab = .terminal
        activeLedgerSubTab = session.lastActiveLedgerSubTab

        // Create terminal view BEFORE resetting hasExited.
        // Setting hasExited = false triggers SwiftUI to swap
        // StoppedSessionView → FocusableTerminalView, which
        // needs session.terminalView to exist.
        session.ensureTerminalView()

        // Reset session state
        session.hasExited = false
        session.exitCode = nil
        session.isRunning = false
        session.userInitiatedStop = false

        // Disable focus reporting (mode 1004) before the view transition.
        // Claude Code enables mode 1004 so SwiftTerm sends ESC[I on focus-in.
        // During resume, the view swap triggers a focus event before the new
        // process is ready to parse it, leaking a stray "I" into the input.
        // The new Claude process will re-enable mode 1004 when it initializes.
        session.terminalView?.feed(text: "\u{1b}[?1004l")

        // Clear the visible screen before resuming so Claude redraws cleanly.
        // ESC[2J = clear screen, ESC[H = cursor home.
        // Note: ESC[3J (clear scrollback) is intentionally omitted to preserve
        // scroll history across resumes.
        session.terminalView?.feed(text: "\u{1b}[2J\u{1b}[H")

        // Callbacks are re-wired automatically by the subscription
        // set up in observeTerminalViewLifecycle when this session
        // was originally registered: ensureTerminalView() above
        // assigned a fresh GalaxyTerminalView to session.terminalView,
        // which fired the subscription, which called
        // wireSessionCallbacks on the new view.

        // Determine executable path: claude-persona for persona sessions, claude for vanilla
        let executablePath: String
        if session.personaName != nil, let cpPath = claudePersonaPath {
            executablePath = cpPath
        } else {
            executablePath = claudePath
        }

        // Start process: --resume if session exists in Claude storage, --session-id if not
        session.startProcess(executablePath: executablePath, resume: canResume)

        // /galaxy:resume is now triggered by the session.resume
        // socket event in EventCoordinator.routeEvent() — no
        // delay needed. The on_resume hook publishes that event
        // once Claude has restored the transcript.

        // Make this the active session
        activeSessionId = session.id
        SessionPersistence.shared.markDirty()

        // Update menu state (session is now running, not resumable)
        updateActiveSessionCanResume()
    }

    /// Clear the active session and auto-handoff when Claude settles.
    func clearActiveSession() {
        guard let session = activeSession, session.isRunning, !session.hasExited else { return }
        clearAndHandoff(session)
    }

    /// Compact the active session and auto-handoff when Claude settles.
    func compactActiveSession() {
        guard let session = activeSession, session.isRunning, !session.hasExited else { return }
        session.sendCommand("/compact")
        // Extra 1s delay after idle gives the TUI time to fully
        // settle after the compact operation completes.
        session.afterNextIdle { [weak session] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak session] in
                session?.sendCommand("/handoff")
            }
        }
    }

    /// Send /clear to a session and queue /handoff after it settles.
    /// Used by clearActiveSession, compactActiveSession, and auto-clear.
    private func clearAndHandoff(_ session: Session) {
        session.sendCommand("/clear")
        session.afterNextIdle { [weak session] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak session] in
                session?.sendCommand("/handoff")
            }
        }
    }

    /// Build the turn state file path for a session.
    /// Matches Crystal TurnState module:
    /// ~/.claude/galaxy/ledger/turn-state/{claude_session_id}.json
    private func turnStateFilePath(
        for session: Session
    ) -> String {
        let home = NSHomeDirectory()
        return "\(home)/.claude/galaxy/ledger/turn-state"
            + "/\(session.claudeSessionId).json"
    }

    /// Read and parse the turn state file for a session.
    /// Returns (uuid, user_message) or nil if file is
    /// missing or unreadable.
    private func readTurnState(
        for session: Session
    ) -> (uuid: String, userMessage: String)? {
        let path = turnStateFilePath(for: session)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path),
              let dict = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any],
              let uuid = dict["uuid"] as? String,
              let msg = dict["user_message"] as? String
        else { return nil }
        return (uuid: uuid, userMessage: msg)
    }

    /// Normalize text for fuzzy matching: strip
    /// non-alphanumeric/non-space characters and condense
    /// runs of whitespace to a single space. This removes
    /// prompt artifacts (❯), non-breaking spaces, and other
    /// terminal rendering differences.
    private static func normalizeForMatch(
        _ text: String
    ) -> String {
        let stripped = text.unicodeScalars.map { scalar in
            if CharacterSet.alphanumerics
                .contains(scalar)
                || scalar == " "
            {
                return Character(scalar)
            }
            return Character(" ")
        }
        return String(stripped)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // Claude Code terminal markers for interrupt detection.
    // Matched with hasPrefix on terminal buffer lines.
    // Note: the space after ⎿ is U+0020 followed by U+00A0
    // (non-breaking space) — this is how Claude Code renders
    // these markers in the terminal.
    private static let stopMarker =
        "  \u{23BF} \u{00A0}Stop says: "
    private static let interruptMarker =
        "  \u{23BF} \u{00A0}Interrupted \u{00B7} "

    /// Check the SwiftTerm buffer for a genuine interrupt.
    /// Scans backwards through the scrollback for the last
    /// stop marker (previous turn boundary), then forward
    /// for an interrupt marker, then verifies the user
    /// message appears between them.
    private func isGenuineInterrupt(
        session: Session,
        userMessage: String
    ) -> Bool {
        guard let tv = session.terminalView,
              let terminal = tv.terminal
        else { return false }
        let buf = terminal.buffer
        let top = buf.linesTop
        let end = top + buf.lines.count
        let scanStart = top

        NSLog(
            "isGenuineInterrupt: top=%d end=%d"
            + " scanStart=%d userMsg='%@'",
            top, end, scanStart,
            String(userMessage.prefix(50))
        )

        // Step 1: Find last stop marker (scan backwards
        // through scrollback)
        var stopRow = -1
        for row in stride(
            from: end - 1, through: scanStart, by: -1
        ) {
            guard let line = terminal
                .getScrollInvariantLine(row: row)
            else { continue }
            let text = line.translateToString(
                trimRight: true
            )
            if text.hasPrefix(Self.stopMarker) {
                stopRow = row
                break
            }
        }
        guard stopRow >= 0 else { return false }

        // Step 2: Find interrupt marker after stop marker
        var interruptRow = -1
        for row in (stopRow + 1)..<end {
            guard let line = terminal
                .getScrollInvariantLine(row: row)
            else { continue }
            let text = line.translateToString(
                trimRight: true
            )
            if text.hasPrefix(Self.interruptMarker) {
                interruptRow = row
                break
            }
        }
        guard interruptRow > stopRow else { return false }

        // Step 3: Concatenate between markers, check
        // for user message. Normalize both sides: strip
        // non-alphanumeric characters and condense
        // whitespace so prompt artifacts (❯, NBSP, etc.)
        // don't prevent matching.
        var combined = ""
        for row in stopRow...interruptRow {
            guard let line = terminal
                .getScrollInvariantLine(row: row)
            else { continue }
            combined += line.translateToString(
                trimRight: true
            )
            combined += " "
        }

        let normalizedCombined =
            Self.normalizeForMatch(combined)
        let normalizedMessage =
            Self.normalizeForMatch(userMessage)

        let match = normalizedCombined.contains(
            normalizedMessage
        )
        NSLog(
            "isGenuineInterrupt: stopRow=%d"
            + " interruptRow=%d match=%d",
            stopRow, interruptRow, match ? 1 : 0
        )
        return match
    }

    /// Detect user interrupts on busy→idle by checking the
    /// turn state file and corroborating with the SwiftTerm
    /// buffer. Records turn:interrupted only when the buffer
    /// confirms a genuine interrupt (stop marker → user
    /// message → interrupt marker chain).
    private func checkForInterrupt(
        for session: Session
    ) {
        guard let ledgerSessionId = session.ledgerSessionId
        else { return }

        guard let captured = readTurnState(for: session)
        else { return }

        guard isGenuineInterrupt(
            session: session,
            userMessage: captured.userMessage
        ) else { return }

        TimelineService.record(
            ledgerSessionId: ledgerSessionId,
            eventType: "turn:interrupted",
            source: "galaxy-app",
            durationIdentifier:
                "turn--\(captured.uuid)",
            detailData: [
                "user_message": captured.userMessage,
            ]
        )

        // Delete only if UUID still matches (we own it)
        let current = readTurnState(for: session)
        if current?.uuid == captured.uuid {
            try? FileManager.default.removeItem(
                atPath: turnStateFilePath(
                    for: session
                )
            )
        }
    }

    /// Called when a turn ends (socket event, interrupt detection,
    /// or fallback timer). Handles all turn-end consumers with the
    /// correct turn duration.
    private func handleTurnEnd(
        for session: Session,
        duration: TimeInterval?
    ) {
        let settings = SettingsManager.shared.settings
        let turnDuration = duration ?? 0

        let isViewingThisSession =
            session.id == activeSessionId
            && activeTab == .terminal
            && isWindowFocused

        // Unread indicator
        let trackUnread = settings.showUnreadIndicator
            || settings.showDockBadge
        let unreadMinBusy: TimeInterval = 3.0
        if trackUnread
            && !isViewingThisSession
            && turnDuration >= unreadMinBusy
        {
            session.hasUnreadResponse = true
            updateDockBadge()
        }

        // Session Idle notification
        if settings.notifySessionIdle
            && !isViewingThisSession
        {
            let minBusy = TimeInterval(
                settings.notifySessionIdleMinBusy
            )
            if turnDuration >= minBusy {
                let minIdle = TimeInterval(
                    settings.notifySessionIdleMinIdle
                )
                pendingIdleNotificationTimers[session.id]?
                    .invalidate()
                pendingIdleNotificationTimers[session.id] =
                    Timer.scheduledTimer(
                        withTimeInterval: minIdle,
                        repeats: false
                    ) { [weak self] _ in
                        guard let self else { return }
                        self.pendingIdleNotificationTimers
                            .removeValue(forKey: session.id)

                        // Re-check: still idle and not viewing?
                        guard !session.isInTurn
                        else { return }
                        let stillViewing =
                            session.id == self.activeSessionId
                            && self.activeTab == .terminal
                            && self.isWindowFocused
                        guard !stillViewing else { return }

                        // Play user-configured sound. Gated on
                        // the same !stillViewing check as the
                        // notification so the audio nudge stays
                        // 1:1 with the banner.
                        SettingsManager.shared.playSound(
                            SettingsManager.shared.settings
                                .notifySessionIdleSound
                        )

                        NotificationService.shared
                            .notifySessionIdle(
                                sessionId: session.id,
                                displayName:
                                    session.displayName,
                                responsePreview:
                                    self.lastResponsePreview(
                                        for: session
                                    ),
                                contextPct:
                                    session
                                    .ledgerContextPercentage,
                                linesAdded:
                                    session.ledgerLinesAdded,
                                linesRemoved:
                                    session.ledgerLinesRemoved
                            )
                    }
            }
        }

        // Auto-clear
        guard settings.autoClearEnabled else { return }

        let threshold = Double(settings.autoClearThreshold)
        guard let contextPct = session.ledgerContextPercentage,
              contextPct > threshold else { return }

        if let lastClear = lastAutoClearTime[session.id],
           Date().timeIntervalSince(lastClear)
               < Self.autoClearCooldown
        {
            return
        }

        NSLog(
            "SessionManager: Auto-clearing %@"
                + " — context at %.0f%%",
            session.sessionRef, contextPct
        )

        if settings.notifyAutoClearOccurred
            && !isViewingThisSession
        {
            NotificationService.shared
                .notifyAutoClearOccurred(
                    sessionId: session.id,
                    displayName: session.displayName,
                    contextPct: Int(contextPct)
                )
        }

        lastAutoClearTime[session.id] = Date()
        clearAndHandoff(session)
    }

    /// Extract a preview of the last assistant response by reading
    /// the session's transcript JSONL file on disk. Scans backwards
    /// from the end to find the most recent assistant message, then
    /// extracts text blocks from its content array.
    ///
    /// This is more reliable than ledger enrichment data at idle time
    /// because Claude Code writes the transcript entry synchronously
    /// before redrawing the prompt, whereas enrichment runs async.
    private func lastResponsePreview(for session: Session) -> String? {
        let transcriptPath = self.transcriptPath(for: session)
        guard FileManager.default.fileExists(atPath: transcriptPath)
        else { return nil }

        // Read the last chunk of the file — assistant messages are
        // typically in the final few KB even for large transcripts.
        guard let fileHandle = FileHandle(forReadingAtPath: transcriptPath)
        else { return nil }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 32_768)
        fileHandle.seek(toFileOffset: fileSize - readSize)
        let tailData = fileHandle.readDataToEndOfFile()

        guard let tail = String(data: tailData, encoding: .utf8)
        else { return nil }

        // Scan lines in reverse to find the last assistant entry
        let lines = tail.components(separatedBy: .newlines)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(
                in: .whitespaces
            )
            guard !trimmed.isEmpty,
                  trimmed.hasPrefix("{") else { continue }

            guard let data = trimmed.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(
                      with: data
                  ) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any]
            else { continue }

            // Extract text from content blocks
            let text: String
            if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.compactMap { block -> String? in
                    guard block["type"] as? String == "text"
                    else { return nil }
                    return block["text"] as? String
                }.joined(separator: " ")
            } else if let str = message["content"] as? String {
                text = str
            } else {
                continue
            }

            guard !text.isEmpty else { continue }
            return truncateForNotification(text)
        }

        return nil
    }

    /// Build the path to a session's Claude Code transcript file.
    private func transcriptPath(for session: Session) -> String {
        let escapedPath = session.workingDirectory
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let home = NSHomeDirectory()
        return "\(home)/.claude/projects/\(escapedPath)"
            + "/\(session.claudeSessionId).jsonl"
    }

    /// Collapse whitespace and truncate text for a notification
    /// banner. Breaks at the last word boundary for readability.
    private func truncateForNotification(
        _ text: String,
        limit: Int = 100
    ) -> String {
        let cleaned = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespaces)

        if cleaned.count <= limit { return cleaned }
        let truncated = String(cleaned.prefix(limit))
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "…"
        }
        return truncated + "…"
    }

    /// Check if Claude has a session saved on disk for the given session ID and working directory
    private func claudeSessionExists(sessionId: String, workingDirectory: String) -> Bool {
        // Claude stores session data in ~/.claude/projects/<escaped-path>/<session-id>.jsonl
        // Path escaping: /Users/foo.bar/baz becomes -Users-foo-bar-baz (slashes AND dots become dashes)
        let escapedPath = workingDirectory
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(escapedPath)

        // Check for the actual session data file (not just the index)
        let sessionFile = claudeDir.appendingPathComponent("\(sessionId).jsonl")
        let exists = FileManager.default.fileExists(atPath: sessionFile.path)

        NSLog("SessionManager: Session file %@.jsonl %@ at %@", sessionId, exists ? "found" : "not found", claudeDir.path)
        return exists
    }

    // MARK: - View State Save/Restore

    // MARK: - Navigation history delegation
    //
    // Thin forwarders to the active session's NavigationCoordinator.
    // Menu actions and chrome buttons call these rather than reach
    // into Session directly, so "no active session" is handled in
    // one place.

    var canNavigateBack: Bool {
        activeSession?.navigationCoordinator.history.canGoBack
            ?? false
    }

    var canNavigateForward: Bool {
        activeSession?.navigationCoordinator
            .history.canGoForward ?? false
    }

    func navigateBack() {
        activeSession?.navigationCoordinator.navigateBack()
    }

    func navigateForward() {
        activeSession?.navigationCoordinator.navigateForward()
    }

    /// Save the current tab/subtab state to the outgoing session.
    private func saveViewState() {
        guard let session = activeSession else { return }
        session.lastActiveTab = activeTab
        session.lastActiveLedgerSubTab = activeLedgerSubTab
    }

    /// Restore tab/subtab state from the incoming session.
    private func restoreViewState(for session: Session) {
        activeTab = session.lastActiveTab
        activeLedgerSubTab = session.lastActiveLedgerSubTab
        drainPendingShows(for: session)
    }

    /// Record an artifact.show intent for a session the user
    /// isn't currently viewing. Overrides that session's
    /// remembered tab to `.artifacts` so the regular tab
    /// restore path lands the user on the right tab when they
    /// later switch to it. Queues the artifact number for the
    /// drain step in `restoreViewState`.
    func queueArtifactShow(
        sessionId: UUID, number: Int32
    ) {
        guard let session = sessions.first(
            where: { $0.id == sessionId }
        ) else { return }
        session.lastActiveTab = .artifacts
        pendingArtifactBySession[sessionId] = number
    }

    /// Snapshot-side mirror of queueArtifactShow. Overrides
    /// remembered tab to `.snapshots`, queues the snapshot
    /// number for drain on next switch.
    func queueSnapshotShow(
        sessionId: UUID, number: Int32
    ) {
        guard let session = sessions.first(
            where: { $0.id == sessionId }
        ) else { return }
        session.lastActiveTab = .snapshots
        pendingSnapshotBySession[sessionId] = number
    }

    /// Drain any queued show intents for the incoming
    /// session. Called after restoreViewState has set
    /// activeTab — the pending number fires the same
    /// published-property that ArtifactsView /
    /// SnapshotsView already watch, so the reader opens
    /// without any additional plumbing.
    private func drainPendingShows(for session: Session) {
        if let num = pendingArtifactBySession.removeValue(
            forKey: session.id
        ) {
            pendingArtifactShow = num
        }
        if let num = pendingSnapshotBySession.removeValue(
            forKey: session.id
        ) {
            pendingSnapshotNumber = num
        }
    }

    func switchTo(sessionId: UUID) {
        guard activeSessionId != sessionId else { return }
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }

        // Suppress navigation history recording on both the
        // outgoing and incoming sessions across the state
        // shuffle below. Without this, the save/restore/drain
        // sequence would push spurious entries into history.
        activeSession?.navigationCoordinator
            .suppressForSessionSwitch()
        session.navigationCoordinator
            .suppressForSessionSwitch()

        saveViewState()
        activeSessionId = sessionId
        restoreViewState(for: session)

        SessionPersistence.shared.markDirty()

        // Clear unread indicator immediately on switch.
        // Done here rather than solely in SessionRow's onChange(of: isSelected)
        // to avoid gesture disambiguation delays when double-click gestures
        // exist on child views. Only clears when on the terminal tab — viewing
        // Ledger or Snapshots keeps the indicator visible.
        if session.hasUnreadResponse && isWindowFocused && activeTab == .terminal {
            session.hasUnreadResponse = false
            updateDockBadge()
        }

        // Update menu state for the newly active session
        updateActiveSessionCanResume()
    }

    func closeSession(sessionId: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        NSLog("SessionManager: closeSession called for session %@", sessionId.uuidString)

        // Archive the session before removal
        let archived = PersistedClosedSession(
            session: sessions[index].toPersistedState(),
            closedAt: Date()
        )
        closedSessions.insert(archived, at: 0)

        // Trim archive if over retention limit
        if closedSessions.count > Self.closedSessionRetentionLimit {
            closedSessions = Array(closedSessions.prefix(Self.closedSessionRetentionLimit))
        }

        // Determine next session to select (prefer next, fall back to previous)
        var nextActiveId: UUID? = nil
        if sessions.count > 1 {
            if index < sessions.count - 1 {
                nextActiveId = sessions[index + 1].id
            } else {
                nextActiveId = sessions[index - 1].id
            }
        }

        // Notify observers before removal (e.g., EventCoordinator cache cleanup)
        onSessionClosed?(sessionId)

        // Clean up auto-clear cooldown and pending notification timers
        lastAutoClearTime.removeValue(forKey: sessionId)
        pendingIdleNotificationTimers[sessionId]?.invalidate()
        pendingIdleNotificationTimers.removeValue(forKey: sessionId)
        NotificationService.shared.sessionClosed(sessionId)

        // Clear session callbacks to stop idle/busy state machine activity
        let session = sessions[index]
        session.onIdleTransition = nil
        session.onTurnStart = nil
        session.onTurnEnd = nil

        // Cancel the terminalView lifecycle observer so it doesn't
        // re-wire callbacks on any post-removal terminalView churn.
        terminalViewSubs.removeValue(forKey: session.id)

        // Remove the session (this will deallocate the terminal view which kills the process)
        sessions.remove(at: index)
        SessionPersistence.shared.markDirty()
        updateDockBadge()

        // Update active session and restore the next session's view state
        if activeSessionId == sessionId {
            activeSessionId = nextActiveId
            if let nextId = nextActiveId,
               let nextSession = sessions.first(where: { $0.id == nextId })
            {
                restoreViewState(for: nextSession)
            }
        }

        NSLog("SessionManager: Session removed, remaining count: %d", sessions.count)
    }

    /// Present a confirmation dialog and dismiss the session if confirmed.
    /// Called by both ⌘⇧W menu action and the hover X button on stopped sessions.
    func confirmAndDismissSession(sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }

        // Only allow dismissal of stopped sessions
        guard session.hasExited else {
            NSLog("SessionManager: Cannot dismiss — session is still running")
            return
        }

        guard let window = NSApp.keyWindow else { return }

        SheetAlert.confirm(
            in: window,
            message: "Confirm dismiss session?",
            detail: """
                "\(session.displayName)" will be removed \
                from the sidebar.
                """,
            confirm: "Confirm"
        ) { [weak self] in
            self?.closeSession(sessionId: sessionId)
        }
    }

    /// Restore a previously closed session to the sidebar.
    /// Creates a new stopped Session from the archived state,
    /// appends to the bottom of the sidebar, and makes it active.
    func restoreSession(closedSession: PersistedClosedSession) {
        // Remove from closed archive
        closedSessions.removeAll { $0.session.id == closedSession.session.id }

        // Create stopped session from persisted state
        let session = Session(restoring: closedSession.session)
        sessions.append(session)
        // Observe terminalView lifecycle so callbacks wire
        // automatically when the user later resumes this session.
        observeTerminalViewLifecycle(for: session)

        // Save outgoing session's view state, then activate restored session
        saveViewState()
        activeSessionId = session.id
        activeTab = .terminal
        activeLedgerSubTab = .identifiers

        SessionPersistence.shared.markDirty()

        NSLog(
            "SessionManager: Restored session %@ (%@), closed sessions remaining: %d",
            session.sessionRef,
            session.displayName,
            closedSessions.count
        )
    }

    /// Whether there's a previous session to switch to (not at top of list)
    var canSwitchToPreviousSession: Bool {
        guard sessions.count > 1,
              let currentId = activeSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }) else { return false }
        return currentIndex > 0
    }

    /// Whether there's a next session to switch to (not at bottom of list)
    var canSwitchToNextSession: Bool {
        guard sessions.count > 1,
              let currentId = activeSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }) else { return false }
        return currentIndex < sessions.count - 1
    }

    /// Switch to the previous session in the list (no wrap)
    func switchToPreviousSession() {
        guard canSwitchToPreviousSession,
              let currentId = activeSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }) else { return }

        switchTo(sessionId: sessions[currentIndex - 1].id)
    }

    /// Switch to the next session in the list (no wrap)
    func switchToNextSession() {
        guard canSwitchToNextSession,
              let currentId = activeSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }) else { return }

        switchTo(sessionId: sessions[currentIndex + 1].id)
    }

    /// Switch to the previous tab (stops at first boundary)
    func switchToPreviousTab() {
        let allTabs = SessionTab.allCases
        guard let currentIndex = allTabs.firstIndex(of: activeTab),
              currentIndex > allTabs.startIndex else { return }
        activeTab = allTabs[allTabs.index(before: currentIndex)]
    }

    /// Switch to the next tab (stops at last boundary)
    func switchToNextTab() {
        let allTabs = SessionTab.allCases
        guard let currentIndex = allTabs.firstIndex(of: activeTab) else { return }
        let nextIndex = allTabs.index(after: currentIndex)
        guard nextIndex < allTabs.endIndex else { return }
        activeTab = allTabs[nextIndex]
    }

    /// Switch to the previous inner tab within the active view (stops at first boundary)
    func switchToPreviousInnerTab() {
        switch activeTab {
        case .ledger:
            let allTabs = LedgerSubTab.allCases
            guard let currentIndex = allTabs.firstIndex(of: activeLedgerSubTab),
                  currentIndex > allTabs.startIndex else { return }
            activeLedgerSubTab = allTabs[allTabs.index(before: currentIndex)]
        default:
            break
        }
    }

    /// Switch to the next inner tab within the active view (stops at last boundary)
    func switchToNextInnerTab() {
        switch activeTab {
        case .ledger:
            let allTabs = LedgerSubTab.allCases
            guard let currentIndex = allTabs.firstIndex(of: activeLedgerSubTab) else { return }
            let nextIndex = allTabs.index(after: currentIndex)
            guard nextIndex < allTabs.endIndex else { return }
            activeLedgerSubTab = allTabs[nextIndex]
        default:
            break
        }
    }

    /// Swap two sessions in the array (used during drag-to-reorder)
    func swapSessions(_ indexA: Int, _ indexB: Int) {
        guard indexA >= 0 && indexA < sessions.count else { return }
        guard indexB >= 0 && indexB < sessions.count else { return }
        sessions.swapAt(indexA, indexB)
        SessionPersistence.shared.markDirty()
    }

    /// Update the dock badge to reflect the current unread session count.
    /// Only updates when the showDockBadge setting is enabled.
    /// Must be called on the main thread (NSDockTile is AppKit).
    func updateDockBadge() {
        guard SettingsManager.shared.settings.showDockBadge else {
            NSApp.dockTile.badgeLabel = nil
            return
        }

        let unreadCount = sessions.filter { $0.hasUnreadResponse }.count
        NSApp.dockTile.badgeLabel = unreadCount > 0 ? "\(unreadCount)" : nil
    }

    /// Extract notification body text from a turn event.
    /// For turn-ending events, prefer assistant_response.
    /// For turn:initiated, use user_message.
    private static func bellNotificationBody(
        from event: TimelineEvent?
    ) -> String? {
        guard let event = event,
              let detailData = event.detailData,
              let data = detailData.data(using: .utf8),
              let dict = try? JSONSerialization
                  .jsonObject(with: data)
                  as? [String: Any]
        else { return nil }

        let text: String?
        switch event.eventType {
        case "turn:completed", "turn:continued":
            text = dict["assistant_response"] as? String
                ?? dict["user_message"] as? String
        case "turn:failed", "turn:interrupted",
             "turn:abandoned":
            text = dict["assistant_response"] as? String
                ?? dict["user_message"] as? String
        case "turn:initiated":
            text = dict["user_message"] as? String
        default:
            text = nil
        }

        guard let raw = text, !raw.isEmpty else {
            return nil
        }

        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.count > 150 {
            return String(cleaned.prefix(147)) + "…"
        }
        return cleaned
    }

    /// Trigger visual bell with 3 flashes, each shorter than the last.
    /// Unconditional — debounce lives one level up in handleBell(for:)
    /// so the whole pipeline (sound + flash + notification) is gated
    /// together, not just the flash.
    private func triggerVisualBell(for session: Session) {
        // Flash durations: 3 flashes at 375ms each
        // Gap between flashes: 100ms
        let flashDurations = [0.375, 0.375, 0.375]
        let gap = 0.1

        var delay = 0.0
        for (index, duration) in flashDurations.enumerated() {
            // Turn on
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                session.visualBellActive = true
            }
            delay += duration

            // Turn off
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                session.visualBellActive = false
            }

            // Add gap before next flash (except after last flash)
            if index < flashDurations.count - 1 {
                delay += gap
            }
        }
    }

    /// Total duration of a single bell pipeline event. Matches the
    /// visual flash sequence (3 flashes × 375ms + 2 gaps × 100ms).
    /// Used as the debounce window in handleBell(for:).
    private static let bellPipelineDuration: TimeInterval =
        (0.375 * 3) + (0.1 * 2)

    /// Subscribe to a session's `$terminalView` so the callback set
    /// below (`wireSessionCallbacks`) fires automatically whenever
    /// the view is (re)created. One subscription per session,
    /// established when the session is first registered. Survives
    /// stop → resume cycles — `releaseTerminalView` writes nil
    /// (subscriber ignores) and `ensureTerminalView` writes a new
    /// view (subscriber re-wires). Removed in `removeSession`.
    private func observeTerminalViewLifecycle(for session: Session) {
        terminalViewSubs[session.id] = session.$terminalView
            .sink { [weak self, weak session] newView in
                guard let self = self,
                      let session = session,
                      let view = newView else { return }
                self.wireSessionCallbacks(
                    for: session, terminalView: view
                )
            }
    }

    /// Single source of truth for wiring SessionManager-owned
    /// callbacks on a session's terminal view. Called by the
    /// observer set up in `observeTerminalViewLifecycle(for:)`
    /// every time `session.terminalView` transitions to non-nil.
    ///
    /// Idempotent: each call replaces any prior wiring on the
    /// current view, so stacking calls doesn't leak handlers.
    /// Session-level callbacks (onTurnStart, onIdleTransition,
    /// onTurnEnd) persist across terminalView recreation but are
    /// re-assigned here for parity with pre-refactor behavior.
    private func wireSessionCallbacks(
        for session: Session,
        terminalView: GalaxyTerminalView
    ) {
        // Process handler — strong ref on Session so it outlives
        // the closure captures below.
        let handler = TerminalProcessHandler(
            session: session, sessionManager: self
        )
        session.processHandler = handler
        terminalView.processDelegate = handler

        // Bell — delegates to the debounced pipeline in handleBell.
        terminalView.onBell = { [weak self, weak session] in
            guard let self = self,
                  let session = session else { return }
            self.handleBell(for: session)
        }

        // Busy-state detection (PTY activity).
        terminalView.onDataReceived = { [weak session] in
            session?.markBusy()
        }

        // Start buffer content monitor.
        terminalView.startContentMonitor()

        // Cancel pending idle notification timer when turn starts.
        session.onTurnStart = { [weak self] session in
            self?.pendingIdleNotificationTimers[session.id]?
                .invalidate()
            self?.pendingIdleNotificationTimers
                .removeValue(forKey: session.id)
        }

        // Micro-idle: only runs interrupt detection.
        session.onIdleTransition = { [weak self] session in
            self?.checkForInterrupt(for: session)
        }

        // Turn-end: all consumer logic (unread, notifications,
        // auto-clear).
        session.onTurnEnd = { [weak self] session, duration in
            self?.handleTurnEnd(for: session, duration: duration)
        }
    }

    /// Handle a bell event from the session's terminal. Single
    /// source of truth for the bell pipeline — plays sound, fires
    /// visual flash (if enabled), and posts a notification (if
    /// enabled and not viewing). Debounced: if a bell is already in
    /// flight for this session, the new event is dropped entirely.
    ///
    /// Called from the `onBell` closure wired in
    /// `wireSessionCallbacks`, and from the debug bell shortcut
    /// via `session.terminalView?.onBell?()`.
    private func handleBell(for session: Session) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard !session.bellDebounceActive else { return }
            session.bellDebounceActive = true

            // Clear the gate after the full pipeline duration so
            // the next bell can fire cleanly.
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.bellPipelineDuration
            ) {
                session.bellDebounceActive = false
            }

            let settings = SettingsManager.shared.settings

            // Play sound (regardless of focus)
            SettingsManager.shared.playSound(settings.bellSound)

            // Visual flash (regardless of focus, honors setting).
            // `bellVisualFlash` gates both cues: the sidebar
            // flash (persistent attention) and an in-pane pulse
            // (immediate in-place acknowledgment). Pulse fires
            // once at the start of the bell sequence; the
            // sidebar continues its 3-flash cadence.
            if settings.bellVisualFlash {
                self.triggerVisualBell(for: session)
                if let view = session.terminalView {
                    TerminalVisualBell.pulse(over: view)
                }
            }

            // Terminal bell notification (honors setting + not viewing)
            guard settings.notifyTerminalBell else { return }
            let isViewing = session.id == self.activeSessionId
                && self.activeTab == .terminal
                && self.isWindowFocused
            guard !isViewing else { return }

            guard let lsid = session.ledgerSessionId else { return }
            let sessionId = session.id
            let displayName = session.displayName

            Task {
                do {
                    let event = try await TimelineQueryService
                        .shared
                        .fetchMostRecentTurnEvent(
                            ledgerSessionId: lsid
                        )
                    let bodyText = Self.bellNotificationBody(from: event)
                    await MainActor.run {
                        NotificationService.shared.notifyTerminalBell(
                            sessionId: sessionId,
                            displayName: displayName,
                            bodyText: bodyText
                        )
                    }
                } catch {
                    // Best-effort — send without body
                    await MainActor.run {
                        NotificationService.shared.notifyTerminalBell(
                            sessionId: sessionId,
                            displayName: displayName,
                            bodyText: nil
                        )
                    }
                }
            }
        }
    }

}

// Handler for terminal process events
class TerminalProcessHandler: NSObject, LocalProcessTerminalViewDelegate {
    weak var session: Session?
    weak var sessionManager: SessionManager?

    init(session: Session, sessionManager: SessionManager) {
        self.session = session
        self.sessionManager = sessionManager
        NSLog("TerminalProcessHandler: Created for session %@", session.sessionRef)
    }

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        NSLog("TerminalProcessHandler: processTerminated called! exitCode: %d", exitCode ?? -999)

        guard let session = session else {
            NSLog("TerminalProcessHandler: session is nil!")
            return
        }

        NSLog("TerminalProcessHandler: Notifying session %@ of exit", session.sessionRef)
        session.processDidExit(exitCode: exitCode ?? -1)

        // Notify SessionManager to update menu state
        sessionManager?.handleSessionExited(sessionId: session.id)

        NSLog("TerminalProcessHandler: Session marked as stopped, kept in sidebar")
    }

    func sizeChanged(source: SwiftTerm.LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Terminal size changed - handled automatically by SwiftTerm
    }

    func setTerminalTitle(source: SwiftTerm.LocalProcessTerminalView, title: String) {
        NSLog("TerminalProcessHandler: setTerminalTitle: %@", title)
    }

    func hostCurrentDirectoryUpdate (source: SwiftTerm.TerminalView, directory: String?) {
        NSLog("TerminalProcessHandler: hostCurrentDirectoryUpdate: %@", directory ?? "nil")
    }
}
