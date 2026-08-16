import Foundation
import AppKit
import Combine
import Galactic

class Session: Identifiable, ObservableObject {
    /// The agent this session runs. The only place Galaxy names one: the
    /// submit bytes, the pacing, the readiness bound, what closes a completion
    /// popup, and which commands never report acceptance all come from here
    /// rather than being assumed of whatever is on the other end of the PTY.
    private let harness: AgentHarness = ClaudeCodeHarness()

    /// What "the prompt was taken" means for a Galaxy session.
    ///
    /// The only half of verification that is Galaxy's to answer. `isInTurn` is
    /// flipped by Claude Code's UserPromptSubmit hook arriving over the socket,
    /// so it is a report from the agent rather than an observation of the
    /// terminal — and nothing observable from the terminal answers this at all.
    /// The bounded poll, the retype, and the retry ceiling all live in Galactic;
    /// this is the value they consume.
    private var submitVerification: SubmitVerification {
        SubmitVerification(
            isAccepted: { [weak self] in self?.isInTurn ?? false },
            isAlive: { [weak self] in
                guard let self else { return false }
                return self.isRunning && !self.hasExited
            }
        )
    }

    /// UUID used for SwiftUI Identifiable AND as Claude's session ID
    let id: UUID

    /// Human-readable session reference for display (e.g., "rich-grass-hides")
    let sessionRef: String

    /// User-assigned name for this session. Galaxy-only — not shared with ledger.
    /// When set, displayName shows "givenName (sessionRef)".
    @Published var givenName: String?

    /// Display string for user-facing contexts that benefit from the
    /// disambiguating session ref (menu, dialogs, notifications,
    /// stopped screen). The sidebar uses `sidebarTitle` instead.
    ///
    /// Three-state givenName logic:
    /// - givenName is non-empty string → "givenName (sessionRef)"
    /// - givenName is nil + suggested name exists → "suggestedName (sessionRef)"
    /// - givenName is nil + no suggested name → bare sessionRef
    /// - givenName is "" (explicitly cleared) → bare sessionRef
    var displayName: String {
        formattedName(includeRef: true)
    }

    /// Sidebar variant of `displayName` that omits the "(sessionRef)"
    /// suffix once the row carries a custom or suggested name — the
    /// ref is redundant there and crowds a narrow, single-line,
    /// tail-truncated column. Unnamed sessions still fall through to
    /// the bare sessionRef, which is their only label.
    var sidebarTitle: String {
        formattedName(includeRef: false)
    }

    /// Builds the three-state name string. When `includeRef` is false
    /// the "(sessionRef)" suffix is dropped from the two named cases;
    /// the unnamed case still returns the bare ref regardless.
    private func formattedName(includeRef: Bool) -> String {
        if let name = givenName, !name.isEmpty {
            return includeRef ? "\(name) (\(sessionRef))" : name
        }
        if givenName == nil, let suggested = ledgerSuggestedName, !suggested.isEmpty {
            return includeRef ? "\(suggested) (\(sessionRef))" : suggested
        }
        return sessionRef
    }

    @Published var isRunning: Bool = false
    @Published var hasExited: Bool = false
    @Published var exitCode: Int32?
    /// True when the session was stopped by the user (stop button, ⌘W).
    /// Prevents "exited unexpectedly" notifications for intentional stops.
    var userInitiatedStop: Bool = false
    /// Whether this session has something waiting the user has not seen.
    ///
    /// Set by `SessionManager.markAttentionWanted(for:)` whenever a notable
    /// event lands on a session nobody is looking at — a turn ending, a bell, a
    /// permission prompt. Cleared by `attentionAutoClear` as soon as one of the
    /// surfaces rendering it is being viewed.
    ///
    /// Three surfaces render it, each gated by its own setting: the sidebar and
    /// collapsed-sidebar dots and the tab dot on `showUnreadIndicator`, the dock
    /// badge count on `showDockBadge`.
    ///
    /// The dock badge resyncs from `didSet` rather than by convention. It used
    /// to be every caller's job to remember, documented here in capitals, and
    /// six sites remembered while three wrote the badge directly and bypassed
    /// the helper — which is what a convention that cannot be enforced buys.
    @Published var hasUnreadResponse: Bool = false {
        didSet {
            guard oldValue != hasUnreadResponse else { return }
            SessionManager.shared.updateDockBadge()
        }
    }
    @Published var visualBellActive: Bool = false

    /// Collapses a burst of bells on this session into one event — no sound,
    /// no flash, no notification for the ones that arrive mid-window.
    ///
    /// Sized from the flash cadence itself rather than from a figure copied
    /// alongside it, so the gate cannot reopen while the flash it is meant to
    /// outlast is still running. The previous arrangement kept a literal here
    /// and described it in a comment as 100ms shorter than the arithmetic
    /// actually gave.
    ///
    /// Deliberately not `@Published`, and its predecessor should not have been.
    /// It is coordination state that no view reads or ever read; publishing it
    /// invalidated all eighteen observers of a session twice per bell, on a
    /// path this codebase separately documents as costing 80–300ms of main
    /// thread per fan-out.
    let bellDebounce = TerminalBellDebounce(
        window: VisualBellCadence.standard.totalDuration
    )

    // MARK: - Turn State
    //
    // Socket-driven turn model: isInTurn is the single source of
    // truth for "Claude is working." Set by startTurn() in
    // response to the timeline.turn:initiated socket event
    // (emitted by the on_user_prompt_submit hook). Cleared by
    // endTurn() in response to turn-end socket events
    // (completed/failed/continued/interrupted).

    /// True when the session is in an active turn (Claude is
    /// working). Driven exclusively by socket events from the
    /// Crystal hooks — Galaxy never optimistically flips this.
    @Published var isInTurn: Bool = false

    /// True once Claude has finished its on_resume / on_startup
    /// hook and is at (or imminently at) the prompt. Driven by
    /// the `session:ready` socket event emitted by the Crystal
    /// hook. Replaces the legacy buffer-scan path that polled
    /// SwiftTerm's `terminal.buffer` for a literal marker line.
    /// Reset to false on `startProcess`, `releaseBackend`, and
    /// `processDidExit` so each new lifecycle starts unready.
    @Published private(set) var isReady: Bool = false

    /// This session's terminal panes, as a unit — the focus memory, the
    /// cross-pane scrollback flag, and the unsaved-work checks.
    ///
    /// Owned here rather than app-wide because the answers are per session:
    /// the quit sheet names which *sessions* hold unsaved notes, which a single
    /// shared registry could not say. Held by the session and not by the pane
    /// host, so registrations survive the stop/resume cycles that destroy and
    /// recreate the host view.
    let paneRegistry = TerminalPaneCoordinator()

    /// Ids of the agents currently running for this session.
    ///
    /// Tracked as a set rather than a counter because the events
    /// driving it are not guaranteed to arrive once per agent:
    /// resuming a subagent re-fires Claude Code's SubagentStart
    /// hook, and an agent that dies abnormally can emit no end
    /// event at all. A counter turns both into permanent drift,
    /// since the decrement clamps at zero and an over-count is
    /// never worked back off. Set membership is idempotent, so
    /// a repeated start and a missing stop are both harmless.
    /// Number of currently running agents.
    ///
    /// A projection of the agents database, never an
    /// accumulator. Whoever last read the database replaces it
    /// wholesale; socket events trigger a read rather than
    /// adjusting this themselves. The distinction is the whole
    /// point: a counter fed by deltas keeps every event it ever
    /// missed, because nothing later can tell it what the right
    /// answer was. A projection is wrong only until the next
    /// read, and every path that could change the number takes
    /// one — an agent event, a session exiting, the socket
    /// reconnecting, or the periodic sweep.
    @Published private(set) var runningAgentCount: Int = 0

    /// Replace the count with what the database just reported.
    func setRunningAgentCount(_ count: Int) {
        runningAgentCount = max(0, count)
    }

    /// When the current turn started (startTurn called).
    /// Used to compute turn duration for notification/unread gates.
    private var turnStartTime: Date?

    /// Read-only accessor for the current turn's start time.
    /// Returns nil when the session is not in a turn. Used by
    /// EventCoordinator's heartbeat log to compute "BUSY for
    /// Ns" without duplicating turn state.
    var currentTurnStartedAt: Date? { turnStartTime }

    /// Persistent callback fired when a new turn starts
    /// (isInTurn goes true). Set by SessionManager to cancel
    /// pending idle notification timers.
    var onTurnStart: ((Session) -> Void)?

    /// Persistent callback fired when the turn ends. Passes
    /// the turn duration (seconds) for consumers that gate on
    /// minimum busy time.
    var onTurnEnd: ((Session, TimeInterval?) -> Void)?

    // MARK: - View State (per-session, not persisted)
    // Tracks which tab/subtab this session was on when the user switched
    // away. Restored by SessionManager when switching back.

    /// Last active main tab for this session. Defaults to terminal.
    var lastActiveTab: SessionTab = .terminal

    /// Last active ledger subtab for this session. Defaults to identifiers.
    var lastActiveLedgerSubTab: LedgerSubTab = .identifiers

    /// Current ledger entries search query. Hoisted from LedgerView
    /// so it survives conditional view teardown on session switch.
    var ledgerEntriesSearchQuery: String = ""

    // MARK: - Reader / detail identifiers (for navigation history)
    //
    // Hoisted from view-local @State so NavigationCoordinator can
    // observe changes (for recording) and mutate directly (for
    // restoration on back/forward). The views themselves still own
    // the resolved full objects (ArtifactSummary, SnapshotDetail,
    // AgentRun); only the identifier lives here.

    /// Number of the artifact currently open in ArtifactsView's
    /// reader. nil when the reader is closed (viewing the index).
    @Published var openArtifactNumber: Int32? = nil

    /// Number of the snapshot currently open in SnapshotsView's
    /// reader. nil when viewing the index.
    @Published var openSnapshotNumber: Int32? = nil

    /// agentId of the agent currently open in AgentsView's detail
    /// view. nil when viewing the index.
    @Published var selectedAgentId: String? = nil

    // MARK: - History title caches
    //
    // Populated by views as they load summaries. Used by
    // NavigationCoordinator to resolve human-readable titles for
    // history entries at push time.

    fileprivate var artifactTitles: [Int32: String] = [:]
    fileprivate var artifactTypes: [Int32: String] = [:]
    fileprivate var snapshotTitles: [Int32: String] = [:]
    fileprivate var agentTitles: [String: String] = [:]

    func recordArtifactInfo(
        number: Int32, title: String, type: String
    ) {
        artifactTitles[number] = title
        artifactTypes[number] = type
    }

    func artifactTitle(for number: Int32) -> String? {
        guard let title = artifactTitles[number] else { return nil }
        let type = artifactTypes[number] ?? "artifact"
        return "(\(type)) — \(title) (Artifact #\(number))"
    }

    func recordSnapshotInfo(number: Int32, title: String) {
        snapshotTitles[number] = title
    }

    func snapshotTitle(for number: Int32) -> String? {
        guard let title = snapshotTitles[number] else { return nil }
        return "\(title) (Snapshot #\(number))"
    }

    func recordAgentInfo(
        id: String, type: String, description: String?
    ) {
        let desc = description ?? "Agent \(id.prefix(8))"
        agentTitles[id] = "(\(type)) — \(desc)"
    }

    func agentTitle(for id: String) -> String? {
        agentTitles[id]
    }

    // MARK: - Navigation coordinator
    //
    // Owns the per-session history stack and observes state
    // changes (tab, subtab, reader/detail identifiers) to
    // record navigation events. Lazy so initialization defers
    // to first access — by then SessionManager.shared has been
    // set up by the app launch path.
    private(set) lazy var navigationCoordinator:
        NavigationCoordinator
        = NavigationCoordinator(
            session: self,
            sessionManager: SessionManager.shared
        )

    // MARK: - Ledger Enrichment Data
    // Populated by EventCoordinator.applyEnrichmentData() on each
    // session.metrics event. Plain var (not @Published) until a
    // specific property is promoted for UI rendering.

    /// Ledger session ID for fast event matching. Set when the event
    /// system first matches this session via session_identifiers array.
    /// Optional because it's not known until the first event or
    /// enrichment call.
    var ledgerSessionId: Int64?

    /// Compact identity tag for diagnostic logging. Re-evaluated on every
    /// access so the ledger session id is picked up as soon as enrichment
    /// assigns it; the stable sessionRef is the fallback before then.
    /// Lets diagnostic logs be filtered per session, e.g.
    /// `grep "Galaxy/dbg/unread" galaxy.log | grep L412` (by ledger id)
    /// or `... | grep rich-grass-hides` (by ref).
    var diagnosticTag: String {
        let sid = ledgerSessionId.map { "L\($0)" } ?? "?"
        return "sid=\(sid) ref=\(sessionRef)"
    }

    /// All Claude session UUIDs accumulated through resumes/clears
    var ledgerSessionIdentifiers: [String]?

    /// Most recent Claude session UUID
    var ledgerCurrentSessionIdentifier: String?

    /// LLM-suggested session name from the ledger. Iteratively improves
    /// across enrichment cycles. Used as the display name fallback when
    /// givenName is nil (never set). Promoted to @Published because it
    /// drives sidebar row 1 display via displayName.
    @Published var ledgerSuggestedName: String?

    /// All known Claude process IDs for this session
    var ledgerClaudePids: [Int]?

    /// Currently active Claude process PID
    var ledgerCurrentClaudePid: Int?

    /// Working directory reported by the ledger.
    /// Promoted to @Published — drives sidebar line 3 display and
    /// StatusLineService polling directory.
    @Published var ledgerCwd: String?

    /// Git root / project directory
    var ledgerProjectDir: String?

    /// Current git branch
    var ledgerGitBranch: String?

    /// Raw model identifier (e.g., "claude-sonnet-4-20250514")
    var ledgerModelId: String?

    /// Human-readable model name (e.g., "Sonnet 4")
    var ledgerModelDisplayName: String?

    /// Claude CLI version string
    var ledgerClaudeVersion: String?

    /// Context window usage (0–100)
    var ledgerContextPercentage: Double?

    /// Tokens consumed so far
    var ledgerTokensUsed: Int?

    /// Token context window maximum
    var ledgerTokensMax: Int?

    /// Running session cost in USD
    var ledgerCostUsd: Double?

    /// Lines of code added this session
    var ledgerLinesAdded: Int?

    /// Lines of code removed this session
    var ledgerLinesRemoved: Int?

    /// ISO timestamp when the ledger session started
    var ledgerStartedAt: String?

    /// ISO timestamp of last ledger update
    var ledgerUpdatedAt: String?

    /// Raw JSON string of suggested name state data (attempts, quality,
    /// finalized, status, exchange_count, last_attempt_at). Parsed inline
    /// by LedgerSuggestedNameView. Not persisted — re-fetched on relaunch.
    var ledgerSuggestedNameData: String?

    /// Monotonically increasing counter bumped after each enrichment
    /// batch. LedgerView observes this single @Published property
    /// instead of promoting all ledger fields to @Published.
    /// Lifecycle: starts at 0, increments on each enrichment,
    /// resets to 0 on app relaunch (Session objects are recreated).
    @Published var ledgerVersion: Int = 0

    /// Persona name for this session (nil for vanilla Claude sessions)
    let personaName: String?

    /// Whether vibe mode was active at launch
    let isVibe: Bool

    /// One-shot closures fired on the next endTurn() call, then
    /// cleared. Used by post-turn workflows (e.g. snapshot/artifact
    /// review-message send after a /galaxy:resume turn completes).
    /// Lifetime is bounded by session death (processDidExit clears)
    /// and by context-reset events (sendCommand for /clear and
    /// /compact clears, since reset invalidates anything queued
    /// against the prior lifecycle).
    private var oneShotTurnEndActions: [() -> Void] = []

    /// Whether the endTurn now running fired one-shot post-turn actions.
    ///
    /// True only for the span of `onTurnEnd`, which is where the auto-clear
    /// decision is taken. An action that has fired may still have work in
    /// flight — the review-message flows wait three seconds before they
    /// send — and a clear landing in that gap wipes the context the message
    /// was written about, leaving it to arrive at an agent that no longer
    /// remembers what it is a review of.
    private(set) var didFirePostTurnActions = false

    /// Whether a context-threshold crossing is still owed an auto-clear.
    ///
    /// Per session, because each session crosses its own line. Starts armed so
    /// a session resumed already over the threshold is cleared at the end of
    /// its first turn rather than after a needless round trip below it, and is
    /// re-armed on a fresh process for the same reason.
    ///
    /// See `AutoClearPolicy` for why this is a latch rather than an interval —
    /// which matters more here than it looks, because Galaxy's reading is
    /// polled by enrichment rather than handed over with the turn that ended,
    /// so an interval can expire against a number nothing has refreshed.
    var autoClearArmed = true

    /// Current terminal font size for this session (transient, not persisted)
    @Published var terminalFontSize: CGFloat {
        didSet {
            applyPerSessionFontSize()
        }
    }

    /// The terminal backend backing this session. Published so
    /// SessionManager can observe lifecycle transitions (creation in
    /// `init`/`ensureBackend`, teardown in `releaseBackend`) and
    /// re-wire its callbacks without duplicating setup code at every
    /// call site. See `SessionManager.observeBackendLifecycle`.
    @Published private(set) var backend: TerminalBackend?

    /// Terminal engine pinned at this session's construction time
    /// (D-pane). In-memory only — not persisted. Re-set by
    /// `ensureBackend` so a resumed session captures the current
    /// global setting fresh.
    private(set) var engine: TerminalEngine = .swiftTerm

    /// Currently-open Shell pane attached to this session, or nil
    /// when no shell is open. Held weakly because the pane's strong
    /// owner is `SplitState` (per-session UI state) — Session just
    /// needs visibility for cross-pane operations like the session-
    /// switch focus-event suppression that
    /// `SessionManager.suppressFocusEventsAcrossPanes` performs.
    /// Auto-clears when SplitState releases its strong ref on close.
    weak var shellPane: ShellTerminalPane?

    /// The session pane's adapter, so a pane-directed command can name this
    /// pane when nothing holds first responder.
    ///
    /// Weak for the same reason `shellPane` is: the strong owner is the view
    /// that caches it, and a pane that cannot be released could not clear this.
    weak var sessionPane: SessionTerminalPane?

    let createdAt: Date
    let workingDirectory: String

    private var cancellables = Set<AnyCancellable>()
    private var terminalCancellables = Set<AnyCancellable>()

    /// Pending post-ready actions registered via `waitForReady`,
    /// keyed by UUID so each subscription can self-remove from the
    /// dictionary when its `.first()` completes. Two additional
    /// cleanup paths beyond self-removal:
    ///   1. `processDidExit` clears the dict on session death.
    ///   2. `sendCommand` for `/clear` and `/compact` clears the
    ///      dict before queueing new post-ready actions, since
    ///      context reset invalidates any pre-queued actions
    ///      that were waiting on the prior lifecycle's
    ///      `session:ready` event.
    private var pendingReadyActions = [UUID: AnyCancellable]()

    /// Whether a post-reset follow-up is still waiting on `session:ready`.
    ///
    /// Read where a decision would put fresh input into the session: a
    /// resume or a compact that has not yet reported ready still owes a
    /// command, and anything sent ahead of it arrives out of order.
    var hasPendingReadyActions: Bool { !pendingReadyActions.isEmpty }

    // MARK: - The inbox

    /// Messages composed for this session and not yet delivered.
    ///
    /// Per session rather than per app, because a message is addressed to a
    /// conversation and not to Galaxy: two sessions each drain at their own
    /// turn ends, and neither can reach the other's queue.
    ///
    /// Everything routed here survives the surface that composed it, which is
    /// the point. A scrollback comment lives only in a web view's textarea, and
    /// that view is torn down before the send — so a send that cannot land has
    /// nowhere to put the text back.
    let inbox = AgentInbox()

    /// Drains this session's inbox whenever it can take a prompt.
    ///
    /// Bound to the session, so its existence is the gate: nothing can drain
    /// into a terminal that is not there.
    private(set) lazy var inboxConsumer = AgentInboxConsumer(
        inbox: inbox, host: self)

    /// Put a composed message in this session's inbox.
    ///
    /// The whole producer-facing surface, and deliberately usable while the
    /// session is stopped: the message being queued is one nobody can retype,
    /// so refusing it because no agent is up would destroy exactly what the
    /// queue exists to keep. It waits for the session to come back.
    ///
    /// `retry` defaults to `.reportOnly` because these payloads are unbounded
    /// composed prose — a retype doubles a message in the case where the text
    /// landed and only the submit was lost, which nothing can tell from a
    /// total loss.
    func enqueueMessage(
        _ text: String,
        sourceLabel: String,
        delivery: AgentInboxEntry.Delivery = .coalescable,
        retry: SubmitRetryPolicy = .reportOnly
    ) {
        inbox.enqueue(
            AgentInboxEntry(
                body: text,
                sourceLabel: sourceLabel,
                delivery: delivery,
                retry: retry))

        // On the standing submit channel rather than a transient one, for
        // the same reason the rest of that channel exists: a queued message
        // is invisible from outside until it lands, and when one does not
        // land the first question is always whether it was ever produced.
        // A producer that reaches the queue and a producer that silently
        // never called are indistinguishable at the terminal, and this is
        // the line that tells them apart.
        SessionSubmit.log(
            "inbox enqueued \(sourceLabel) — \(text.utf8.count) bytes,"
                + " \(inbox.entries.count) waiting")

        inboxConsumer.wake()
    }

    init(workingDirectory: String, sessionRef: String, personaName: String? = nil, isVibe: Bool = false, resumeSessionId: UUID? = nil) {
        // Use provided resume UUID if resuming a specific session, otherwise generate new
        self.id = resumeSessionId ?? UUID()
        self.sessionRef = sessionRef
        self.personaName = personaName
        self.isVibe = isVibe
        self.claudeSessionId = self.id.uuidString.lowercased()
        self.createdAt = Date()
        self.workingDirectory = workingDirectory

        // Initialize terminal font size from the settings default, held
        // inside the zoom window — the setting has never been through a zoom
        // gesture, so nothing has bounded it yet.
        self.terminalFontSize = TerminalFontSizeBounds.standard.clamped(
            SettingsManager.shared.settings.defaultTerminalFontSize
        )

        // Create terminal backend with default configuration.
        // Engine is pinned to whichever was active at construction
        // time and stays for this session lifecycle.
        self.engine = SettingsManager.shared.settings.terminalEngine
        self.backend = TerminalBackendFactory.make(
            engine: self.engine,
            kind: .session,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )

        configureTerminal()
    }

    /// Push the current `AppSettings` model into the backend
    /// and subscribe to future changes so they apply
    /// automatically. Called from `init` and `ensureBackend`
    /// after the backend is constructed, handing the apply this
    /// session's own font size rather than the configured
    /// default.
    private func configureTerminal() {
        guard let backend = backend else { return }

        // Initial apply of the full settings model + per-session
        // font size override + cursor style. Cursor is applied
        // explicitly (not via applySettings) because SwiftTerm
        // fuses shape + blink into one value; the shared terminal
        // cursor settings drive this pane's native caret, which is
        // Claude's prompt cursor now that it's no longer hidden.
        backend.applySettings(
            SettingsManager.shared.settings, fontSize: terminalFontSize
        )
        // Show the engine's own caret: it is Claude's prompt cursor, since
        // Claude draws none of its own. Asserted here, beside the rest of this
        // terminal's appearance, rather than from the view that happens to
        // mount it — the other app already does it here, and a backend
        // outlives the views that come and go over it.
        backend.setCaretHidden(false)
        backend.applyCursor(
            style: SettingsManager.shared.settings.terminalCursorStyle,
            blink: SettingsManager.shared.settings.terminalCursorBlink
        )

        // Re-apply on every settings change. Stored in
        // `terminalCancellables` so `releaseBackend()` can
        // cancel these independently of non-terminal
        // subscriptions.
        SettingsManager.shared.$settings
            .removeDuplicates()
            .dropFirst()  // Skip current value (already applied above)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                guard let self else { return }
                self.backend?.applySettings(
                    settings, fontSize: self.terminalFontSize
                )
                self.backend?.applyCursor(
                    style: settings.terminalCursorStyle,
                    blink: settings.terminalCursorBlink
                )
            }
            .store(in: &terminalCancellables)
    }

    /// Push this session's own size to the backend, for the
    /// zoom gestures.
    ///
    /// Only the font — a zoom has no business rebuilding the
    /// colour table or reallocating scrollback, which is why
    /// this is not a settings re-apply.
    private func applyPerSessionFontSize() {
        guard let backend = backend else { return }
        let family = SettingsManager.shared.settings.terminalFontFamily
        backend.setFont(
            resolveTerminalFont(
                family: family, size: terminalFontSize
            )
        )
    }

    /// Create the terminal backend if it doesn't exist yet.
    /// Called by SessionManager before resuming a stopped session.
    /// Re-pins the session's engine to the current global setting
    /// (so a resume after the user flipped engines picks up the
    /// new choice) and runs full configuration (theme, font,
    /// scrollback, observers).
    func ensureBackend() {
        guard backend == nil else { return }
        self.engine = SettingsManager.shared.settings.terminalEngine
        self.backend = TerminalBackendFactory.make(
            engine: self.engine,
            kind: .session,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        configureTerminal()
        NSLog(
            "Session[%@]: Created terminal backend on demand "
            + "(engine=%@)",
            sessionRef, self.engine.rawValue
        )
    }

    /// Release the terminal backend to free memory (~32MB
    /// scrollback buffer). Called after a session exits and the
    /// terminal is no longer needed. Safe to call multiple times.
    /// A subsequent `ensureBackend()` will recreate everything.
    ///
    /// Does NOT call `removeFromSuperview()` on the backend's view —
    /// SwiftUI manages the view hierarchy. The TerminalHostView
    /// holds its own strong reference and releases it when SwiftUI
    /// tears down the FocusableTerminalView during the hasExited
    /// transition.
    func releaseBackend() {
        guard backend != nil else { return }

        // Clear callbacks to break any retain cycles. The backend
        // owns its own LPTV delegate plumbing internally (e.g.
        // `SwiftTermBackend` conforms to LPTV directly), so
        // releasing the backend drops that automatically.
        backend?.onBell = nil
        backend?.onProcessTerminated = nil

        // Clear readiness — a future ensureBackend() +
        // startProcess() cycle will re-arm via session:ready.
        isReady = false

        // Release the backend — TerminalHostView retains its own
        // copy of the underlying view until SwiftUI tears it down
        // via the hasExited transition.
        backend = nil

        // Cancel terminal-specific Combine subscriptions only.
        // ensureBackend() will re-subscribe via configureTerminal().
        // Uses a dedicated set so non-terminal subscriptions in
        // cancellables are unaffected.
        terminalCancellables.removeAll()

        NSLog("Session[%@]: Released terminal backend", sessionRef)
    }

    /// The zoom window this session's terminal obeys.
    ///
    /// Named once and delegated to rather than restated: the shell pane
    /// reaches the same rule through the engine's own pane defaults, and two
    /// spellings of one window is how the two panes of a single split come to
    /// stop at different limits or move by different steps.
    private var fontSizeBounds: TerminalFontSizeBounds { .standard }

    /// Increase terminal font size by one step
    func increaseTerminalFontSize() {
        terminalFontSize = fontSizeBounds.increased(from: terminalFontSize)
    }

    /// Decrease terminal font size by one step
    func decreaseTerminalFontSize() {
        terminalFontSize = fontSizeBounds.decreased(from: terminalFontSize)
    }

    /// Check if terminal font size can be increased
    var canIncreaseTerminalFontSize: Bool {
        fontSizeBounds.canIncrease(from: terminalFontSize)
    }

    /// Check if terminal font size can be decreased
    var canDecreaseTerminalFontSize: Bool {
        fontSizeBounds.canDecrease(from: terminalFontSize)
    }

    /// Reset terminal font size to the default from settings.
    ///
    /// Clamped, because the setting has never been through a zoom gesture and
    /// so was never bounded by one. A persisted size from outside the window
    /// would otherwise leave one direction permanently dead.
    func resetTerminalFontSize() {
        terminalFontSize = fontSizeBounds.clamped(
            SettingsManager.shared.settings.defaultTerminalFontSize
        )
    }

    /// Claude's session ID used for --session-id / --resume flags
    /// and event matching. Updated from ledger enrichment when the
    /// session identifier changes (e.g., after /clear or resume).
    /// Initialized from session.id at creation.
    /// Promoted to @Published so StoppedSessionView re-renders
    /// resumeCommand when the identifier changes.
    @Published var claudeSessionId: String

    /// Send a slash command to the terminal (e.g., "/clear", "/compact").
    /// Only works when session is running.
    ///
    /// By default the send is verified: Galactic watches for the
    /// `isInTurn` flip that Claude Code's UserPromptSubmit hook drives,
    /// and retypes the prompt if it never arrives. Readiness itself is
    /// not observable from here — five signals were measured and every
    /// one reported ready against a prompt that did not exist — so this
    /// path is correct because it is confirmed, not because it is timed.
    ///
    /// Pass `verifyAccepted: false` only when no such confirmation can
    /// ever arrive. "The caller already knows Claude is ready" is not a
    /// reason — `session:ready` was the belief that made resume unreliable
    /// for a week, and it fires before the input layer paints. Nor is "a
    /// person is watching this one": that reasoning kept the acceptance
    /// signal off the sends carrying the most text, and the thing it was
    /// really avoiding was the retype, not the detection.
    ///
    /// The commands that genuinely cannot be confirmed are detected rather
    /// than declared — see `isContextResetCommand` — so a caller does not
    /// have to remember which they are.
    ///
    /// `retry` is the separate question: whether a prompt found missing
    /// should be retyped. Bounded payloads say yes. An unbounded one says
    /// `.reportOnly`, because retyping doubles a prompt in the case where
    /// the text landed and only the submit was lost, and nothing here can
    /// distinguish that from a total loss.
    /// Detect the commands that bypass the agent's prompt-submit pipeline, so
    /// no acceptance report will ever arrive for them.
    ///
    /// The set is the harness's to name — which commands an agent intercepts
    /// is a fact about that agent, and Galaxy held its own copy of the answer
    /// for as long as there was nowhere else to put it. What Galaxy still owns
    /// is the *response*: it treats a match as a synthetic Galaxy-initiated
    /// turn, optimistically calling `startTurn`, because no `turn:initiated`
    /// socket event is coming.
    private func isContextResetCommand(_ command: String) -> Bool {
        harness.acceptanceBypassingCommands.contains(
            command.trimmingCharacters(in: .whitespaces)
        )
    }

    /// Trim this session's terminal scrollback before a context reset,
    /// so the post-reset session opens on a clean buffer instead of
    /// inheriting the prior session's history. Routes through the
    /// backend's trim (a local scrollback wipe plus a viewport reflow);
    /// nothing is queued against the turn lifecycle.
    func trimTerminalBuffer() {
        backend?.trimBuffer()
    }

    /// Reflow this session's terminal viewport — send a form feed
    /// (Ctrl+L) so the child repaints its current screen. Used on
    /// resume, once the session is ready, to force a clean repaint of
    /// the restored view. Leaves the scrollback untouched.
    func reflowTerminalBuffer() {
        backend?.reflowBuffer()
    }

    /// Ask Claude to run one of Galaxy's skills.
    ///
    /// A named seam rather than callers writing the slash themselves.
    /// Invoking a skill and triggering a Claude Code built-in are separate
    /// intents that happen to share a syntax, and keeping them apart means
    /// submission mechanics can change without auditing every call site for
    /// literal command text.
    ///
    /// The leading slash opens Claude Code's completion popup, which consumes
    /// the submit keystroke. `sendCommand` deals with that for every automated
    /// prompt — there is nothing skill-specific about it.
    func sendSkill(
        _ skill: String, verifyAccepted: Bool = true
    ) {
        sendCommand("/\(skill)", verifyAccepted: verifyAccepted)
    }

    /// - Parameter outcome: Runs exactly once with what became of the prompt,
    ///   after any retries have settled — including on the paths that refuse to
    ///   send at all. A caller holding the message needs an answer on every
    ///   path, because silence here is indistinguishable from a verification
    ///   still running and would leave it waiting forever.
    func sendCommand(
        _ command: String,
        verifyAccepted: Bool = true,
        retry: SubmitRetryPolicy = .retype,
        outcome: ((SubmitOutcome) -> Void)? = nil
    ) {
        guard isRunning && !hasExited else {
            SessionSubmit.log("sendCommand refused — session not running")
            outcome?(.abandoned)
            return
        }

        // Capture pre-send turn state. If we're already in a turn,
        // the on_user_prompt_submit hook's turn:initiated event
        // can't serve as a submit-acceptance signal (isInTurn is
        // already true), so skip verification and fall back to
        // fire-and-forget.
        let wasInTurn = isInTurn

        // Whether an acceptance report can arrive at all. Detected from the
        // harness rather than left to the caller — a caller that forgot would
        // wait out the full window on every context reset and then retype one.
        let bypassesAcceptance = isContextResetCommand(command)

        // Galaxy-initiated context-reset commands (/clear,
        // /compact) bypass Claude Code's UserPromptSubmit hook
        // entirely — they're intercepted at the TUI level
        // before the prompt-submit pipeline runs. As a result,
        // no turn:initiated socket event ever fires for them
        // and Galaxy would never enter a turn. We compensate by
        // treating these as synthetic turns: optimistically
        // startTurn here, and rely on the matching
        // context:cleared / context:compacted socket event
        // (handled in EventCoordinator) to call endTurn.
        //
        // Also reset isReady so that the post-reset /handoff
        // chain (waitForReady) waits for the matching
        // session:ready event (ref="clear"/"compact") emitted
        // from on_clear / on_compact rather than firing
        // immediately on the previous resume's stale isReady=true.
        //
        // Context reset also invalidates anything queued against
        // the prior lifecycle: post-ready actions (e.g., a
        // /handoff still waiting on a previous compact's
        // session:ready) and post-turn-end actions (e.g., a
        // queued review-message send). Clear both before this
        // cycle's actions register so the new lifecycle's events
        // fire only this cycle's actions.
        if bypassesAcceptance {
            startTurn(source: "sendCommand:\(command)")
            isReady = false
            pendingReadyActions.removeAll()
            oneShotTurnEndActions.removeAll()

            // Both of the steps below used to belong to the callers, and both
            // moved here for the same reason: a reset can now arrive through
            // the inbox, which puts an unknown amount of time between deciding
            // to reset and writing one. Anything a caller does up front happens
            // in the wrong context by the time the command actually lands.
            //
            // The trim is the visible half. Trimming at the call site wipes a
            // buffer the agent then fills again before the reset goes out, so
            // the post-reset session opens on exactly the history the trim was
            // for.
            trimTerminalBuffer()

            // The follow-up is the half that breaks silently. Registered after
            // the removeAll above, so this cycle's action survives the clearing
            // of the last one's — and registered at the moment of writing
            // rather than by the caller, because readiness is reset on the line
            // above. A caller registering before the write asks a session that
            // is still ready to wait for readiness, gets no wait at all, and
            // sends its follow-up into the context this command is about to
            // throw away.
            waitForReady { [weak self] in
                self?.sendSkill("handoff")
            }
        }

        // One trailing space, and it is load-bearing — do not tidy it away.
        //
        // A leading slash opens Claude Code's completion popup, and the popup
        // consumes the submit keystroke, which made the prompts Galaxy drives
        // itself the least reliable ones in the app: the text landed and then
        // nothing submitted it. The popup filters on the token under the
        // cursor, so a space ends that token, leaves nothing to match, and
        // closes it. Being a state change in the TUI rather than a wait for
        // one, it needs no keystroke paced against a render nobody can observe.
        //
        // It rides in the same write as the command deliberately. Sending it as
        // a separately paced piece was considered and is unnecessary: the popup
        // closes on batched input, measured against /clear and /handoff, so
        // splitting it would add a moving part to fix something that is not
        // broken.
        //
        // Unconditional, because branching on it would buy nothing: Claude Code
        // trims the input, so a plain message carries the space harmlessly, and
        // slash commands take arguments, so an empty one parses as none.
        //
        // Composed inside the delivery seam rather than here, so what closes a
        // completion popup is the agent's answer, and so a retype re-sends
        // exactly what the first attempt sent.

        // Anchors the submit diagnostics: everything that follows is relative
        // to this line, and it is the only one naming the session and the
        // decisions this app made. Logged before the write rather than after,
        // so a readiness timeout still leaves a record of what was attempted.
        SessionSubmit.log(
            "sendCommand session=\(id.uuidString.prefix(8)) "
                + "verifyAccepted=\(verifyAccepted) wasInTurn=\(wasInTurn) "
                + "bypasses=\(bypassesAcceptance) retry=\(retry)"
        )

        guard let backend = backend else {
            SessionSubmit.log("  no backend — nothing sent")
            outcome?(.abandoned)
            return
        }

        // Opt out by value, not by skipping the call. Three reasons a send is
        // unverifiable, and all of them are about whether a report can arrive
        // rather than whether anyone would notice: the caller has independent
        // confirmation, the command bypasses the agent's prompt pipeline, or a
        // turn is already running so there is no turn-start left to wait for.
        let verifiable = verifyAccepted && !wasInTurn && !bypassesAcceptance

        backend.deliverPrompt(
            command,
            harness: harness,
            isAlive: { [weak self] in
                guard let self else { return false }
                return self.isRunning && !self.hasExited
            },
            verification: verifiable ? submitVerification : nil,
            retry: retry,
            outcome: outcome
        )
    }

    // MARK: - Turn State (socket-driven)

    /// Called when a turn-start signal arrives (socket
    /// turn:initiated event, or sendCommand). Sets
    /// isInTurn and fires the onTurnStart callback.
    ///
    /// `ref` is the timeline event row ID (when called from
    /// a socket event) — surfaced in the log so an agent can
    /// `grep "ref=N"` to correlate state transitions with
    /// `galaxy-timeline list --json` rows.
    func startTurn(
        source: String = "unknown",
        ref: String? = nil
    ) {
        let refTag = ref.map { " ref=\($0)" } ?? ""
        if isInTurn {
            // Silent bail-out under the old code path;
            // surfaced now so a stale-busy session that
            // swallows fresh turn:initiated events leaves
            // an obvious fingerprint in the log.
            GalaxyLog.events(
                "[\(sessionRef)] TurnState:"
                + " startTurn IGNORED (already in turn)"
                + "\(refTag) source=\(source)"
            )
            return
        }
        GalaxyLog.events(
            "[\(sessionRef)] TurnState: startTurn"
            + "\(refTag) source=\(source)"
            + " isInTurn: false→true"
        )
        isInTurn = true
        turnStartTime = Date()
        onTurnStart?(self)
    }

    /// Called when an authoritative turn-end signal
    /// arrives (socket event). Clears turn state and
    /// fires the onTurnEnd callback with the turn's
    /// duration.
    ///
    /// `ref` mirrors `startTurn` — the timeline event row
    /// ID, surfaced in the log for grep-based correlation
    /// with the timeline DB.
    func endTurn(
        source: String = "unknown",
        ref: String? = nil
    ) {
        // Deferred so it runs on the way out of every path, including the one
        // just below that returns without a transition.
        //
        // That early return used to skip it, and the queue paid for it: an end
        // arriving for a turn already closed is precisely when a message left
        // over from a failed attempt gets its next chance, and it was the one
        // moment nothing woke. "Wake liberally, gate strictly" only works if
        // the waking is actually liberal.
        //
        // Unconditional, including the interrupt this app infers from a
        // keystroke rather than receives. Suppressing that one was tried and
        // reverted: it bought almost nothing, because a wrong interrupt clears
        // the turn flag either way and the next wake from any source drains
        // through the same open window. What it cost was real — a reader who
        // aborts a turn and walks away leaves the message sitting beside an
        // idle agent. False interrupts are answered where they are made, in
        // `TurnInterrupt`.
        defer { inboxConsumer.wake() }

        let refTag = ref.map { " ref=\($0)" } ?? ""
        if !isInTurn {
            // Silent bail-out under the old code path;
            // surfaced now so a stale-idle session that
            // swallows turn:completed events leaves an
            // obvious fingerprint.
            GalaxyLog.events(
                "[\(sessionRef)] TurnState:"
                + " endTurn IGNORED (not in turn)"
                + "\(refTag) source=\(source)"
            )
            return
        }
        GalaxyLog.events(
            "[\(sessionRef)] TurnState: endTurn"
            + "\(refTag) source=\(source)"
            + " isInTurn: true→false"
        )
        isInTurn = false

        let duration = turnStartTime.map {
            Date().timeIntervalSince($0)
        }
        turnStartTime = nil

        // Drain one-shot post-turn actions. Drain BEFORE
        // calling them so the source array is empty before
        // any action runs — protects against an action that
        // re-enters endTurn or re-registers a new one-shot.
        let firedPostTurnActions = !oneShotTurnEndActions.isEmpty
        if firedPostTurnActions {
            let actions = oneShotTurnEndActions
            oneShotTurnEndActions.removeAll()
            for action in actions {
                action()
            }
        }

        // Raised across onTurnEnd only, so the auto-clear decision taken
        // inside it can see that work is still on its way out.
        didFirePostTurnActions = firedPostTurnActions
        onTurnEnd?(self, duration)
        didFirePostTurnActions = false
    }

    /// Register a closure to fire on the next endTurn(). Fires
    /// once, then unregisters. If the session is currently in a
    /// turn, the action waits for that turn to end. If between
    /// turns, the action waits for the next startTurn → endTurn
    /// cycle. Multiple actions can be queued; all fire together
    /// on the next endTurn.
    func onceAfterTurnEnd(_ action: @escaping () -> Void) {
        oneShotTurnEndActions.append(action)
    }

    /// Marks this session as ready. Called from
    /// EventCoordinator on receipt of a `session:ready`
    /// socket event (refs: resume / clear / compact).
    /// Idempotent — repeat calls during the same lifecycle
    /// are no-ops. Reset to false on `startProcess`,
    /// `releaseBackend`, `processDidExit`, and inside
    /// `sendCommand` for context-reset commands.
    func markReady() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.isRunning, !self.hasExited
            else { return }
            if !self.isReady {
                self.isReady = true
                NSLog(
                    "Session[%@]: markReady fired",
                    self.sessionRef
                )
            }
            // The other moment worth waking for, and the one a turn end cannot
            // cover: `/clear` and `/compact` are intercepted before the prompt
            // pipeline, so they produce no Stop and end no turn. A queue that
            // only watched turn ends would sit through a context reset waiting
            // for a boundary that never comes. This also catches a session
            // coming back with messages queued while it was down.
            self.inboxConsumer.wake()
        }
    }

    /// Run `action` once the session is ready. Fires
    /// immediately if already ready; otherwise subscribes
    /// to `$isReady` and fires on the first true value.
    ///
    /// The wait is bounded by session lifetime and by
    /// context-reset events: `processDidExit` clears any
    /// pending actions on session death, and `sendCommand`
    /// for `/clear` / `/compact` clears them before
    /// queueing new ones (since a context reset
    /// invalidates anything queued against the prior
    /// lifecycle). No wall-clock timeout — `/compact` on a
    /// large session can take well over 30 seconds for
    /// Claude to summarize before its `session:ready`
    /// fires, and a fixed timeout there silently dropped
    /// the queued `/handoff`.
    func waitForReady(
        then action: @escaping () -> Void
    ) {
        if isReady {
            action()
            return
        }

        let id = UUID()
        pendingReadyActions[id] = $isReady
            .filter { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] _ in
                    // Self-remove when our `.first()`
                    // finishes. Fires after delivery;
                    // explicit cancel via `removeAll`
                    // bypasses this path (Combine
                    // doesn't deliver completion on
                    // upstream cancel) but the entry
                    // is already removed by then.
                    self?.pendingReadyActions
                        .removeValue(forKey: id)
                },
                receiveValue: { _ in action() }
            )
    }

    /// Returns the CLI command to resume this session outside of Galaxy.
    /// Uses `claude-persona <name>` for persona sessions, `claude` for vanilla.
    var resumeCommand: String {
        var cmd = "cd \(workingDirectory)"
        if let persona = personaName {
            cmd += " && claude-persona \(persona)"
            cmd += " --resume \(claudeSessionId)"
            if isVibe {
                cmd += " --vibe"
            }
        } else {
            cmd += " && claude --resume \(claudeSessionId)"
            if isVibe {
                cmd += " --dangerously-skip-permissions"
            }
        }
        return cmd
    }

    // MARK: - Persistence

    /// Snapshot this session's persistable state.
    ///
    /// Twenty-three fields, mirrored by `init(restoring:)` below. This
    /// direction is compiler-checked: `PersistedSession` has no hand-written
    /// initialiser, so a field added to it makes this call a missing-argument
    /// error. The other direction is not.
    func toPersistedState() -> PersistedSession {
        PersistedSession(
            id: id,
            sessionRef: sessionRef,
            givenName: givenName,
            claudeSessionId: claudeSessionId,
            workingDirectory: workingDirectory,
            personaName: personaName,
            isVibe: isVibe,
            createdAt: createdAt,
            ledgerSessionId: ledgerSessionId,
            ledgerSessionIdentifiers: ledgerSessionIdentifiers,
            ledgerSuggestedName: ledgerSuggestedName,
            ledgerCwd: ledgerCwd,
            ledgerProjectDir: ledgerProjectDir,
            ledgerGitBranch: ledgerGitBranch,
            ledgerModelDisplayName: ledgerModelDisplayName,
            ledgerContextPercentage: ledgerContextPercentage,
            ledgerTokensUsed: ledgerTokensUsed,
            ledgerTokensMax: ledgerTokensMax,
            ledgerCostUsd: ledgerCostUsd,
            ledgerLinesAdded: ledgerLinesAdded,
            ledgerLinesRemoved: ledgerLinesRemoved,
            ledgerStartedAt: ledgerStartedAt,
            ledgerUpdatedAt: ledgerUpdatedAt
        )
    }

    /// Restore a session from persisted state. Creates in stopped
    /// state with no backend and no running process. The backend
    /// is lazily created by ensureBackend() on resume.
    /// Rebuild from the persisted shape.
    ///
    /// The silent half of the pair. A field added to `PersistedSession` and to
    /// `toPersistedState()` but not read here compiles, writes correctly, and
    /// then quietly fails to come back — there is no test for this, so confirm
    /// a new field by quitting and relaunching rather than by reading.
    init(restoring state: PersistedSession) {
        self.id = state.id
        self.sessionRef = state.sessionRef
        self.claudeSessionId = state.claudeSessionId
        self.createdAt = state.createdAt
        self.workingDirectory = state.workingDirectory
        self.personaName = state.personaName
        self.isVibe = state.isVibe
        // Clamped for the same reason as the other initializer: a settings
        // value has never been bounded by a zoom gesture.
        self.terminalFontSize = TerminalFontSizeBounds.standard.clamped(
            SettingsManager.shared.settings.defaultTerminalFontSize
        )

        // No backend — stopped sessions don't need one.
        // ensureBackend() creates it on resume.
        self.backend = nil

        // Restore Galaxy-only state
        self.givenName = state.givenName

        // Stopped state — no running process
        self.isRunning = false
        self.hasExited = true

        // Restore ledger enrichment data (immediate sidebar content)
        self.ledgerSessionId = state.ledgerSessionId
        self.ledgerSessionIdentifiers = state.ledgerSessionIdentifiers
        self.ledgerSuggestedName = state.ledgerSuggestedName
        self.ledgerCwd = state.ledgerCwd
        self.ledgerProjectDir = state.ledgerProjectDir
        self.ledgerGitBranch = state.ledgerGitBranch
        self.ledgerModelDisplayName = state.ledgerModelDisplayName
        self.ledgerContextPercentage = state.ledgerContextPercentage
        self.ledgerTokensUsed = state.ledgerTokensUsed
        self.ledgerTokensMax = state.ledgerTokensMax
        self.ledgerCostUsd = state.ledgerCostUsd
        self.ledgerLinesAdded = state.ledgerLinesAdded
        self.ledgerLinesRemoved = state.ledgerLinesRemoved
        self.ledgerStartedAt = state.ledgerStartedAt
        self.ledgerUpdatedAt = state.ledgerUpdatedAt

        // No configureTerminal() — nothing to configure
    }

    func startProcess(executablePath: String, resume: Bool = false) {
        // Start process directly (not via shell) so the backend can
        // properly monitor it. No backend means nothing to start.
        guard backend != nil else {
            NSLog("Session: Cannot start process - no backend")
            return
        }

        // Set readiness/running synchronously, before the environment
        // capture is dispatched. resumeSession() registers its
        // waitForReady action and refreshes menu state immediately
        // after this call returns, and both read these flags. The PTY
        // spawn itself happens on the main-thread hop below; the
        // session:ready event that drives the queued /galaxy:resume
        // only arrives once the resumed hook lifecycle completes — long
        // after the spawn — so deferring the spawn is safe.
        //
        // Reset readiness — each new lifecycle starts unready. The
        // on_resume / on_startup hook emits `session:ready` once it
        // completes, flipping this back to true via markReady().
        isReady = false
        isRunning = true

        // A fresh process is a fresh crossing. A session resumed above the
        // line should be cleared at the end of its first turn, not made to
        // wait for a reading below a line it is nowhere near.
        autoClearArmed = true

        // Build args and determine executable.
        var args: [String] = []
        let execName: String

        if let persona = personaName {
            // Persona session: launch via claude-persona
            execName = "claude-persona"
            args.append(persona)

            if resume {
                args.append("--resume")
                args.append(claudeSessionId)
                NSLog("Session: Resuming persona '%@' session %@ in %@", persona, claudeSessionId, workingDirectory)
            } else {
                args.append("--session-id")
                args.append(claudeSessionId)
                NSLog("Session: Starting persona '%@' session with ID %@", persona, claudeSessionId)
            }

            if isVibe {
                args.append("--vibe")
            }
        } else {
            // Vanilla Claude session
            execName = "claude"

            if resume {
                args.append("--resume")
                args.append(claudeSessionId)
                NSLog("Session: Resuming Claude session %@ in %@", claudeSessionId, workingDirectory)
            } else {
                args.append("--session-id")
                args.append(claudeSessionId)
                NSLog("Session: Starting new Claude session with ID %@", claudeSessionId)
            }

            if isVibe {
                args.append("--dangerously-skip-permissions")
            }
        }

        // Vanilla Claude sessions need CLAUDE_CLI_SESSION_ID in the env;
        // persona sessions get it via claude-persona's --settings mechanism.
        let injectSessionId = (personaName == nil)
        let sessionId = claudeSessionId

        // Sourcing the login profile can take ~0.2-0.3s, so capture the
        // environment off the main thread, then spawn back on main. This
        // gives the session the same environment a terminal (the Shell
        // pane) gets — profile secrets, full PATH, locale — instead of
        // launchd's minimal env.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard self != nil else { return }
            let envArray = Self.buildChildEnvironment(
                injectSessionId: injectSessionId,
                sessionId: sessionId
            )

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard let backend = self.backend else {
                    // Backend released between the synchronous guard above
                    // and now (effectively impossible mid-start). Undo the
                    // optimistic running state rather than leave a phantom.
                    self.isRunning = false
                    NSLog("Session: backend released before spawn for %@", self.sessionRef)
                    return
                }
                backend.startProcess(
                    executable: executablePath,
                    args: args,
                    environment: envArray,
                    execName: execName,
                    currentDirectory: self.workingDirectory
                )
                NSLog("Session: Started process for %@ in %@", self.sessionRef, self.workingDirectory)
            }
        }
    }

    /// Build the child process environment. Runs OFF the main thread
    /// because the login-shell capture sources the profile (~0.2-0.3s).
    ///
    /// Base is the user's login-shell environment (captured via
    /// `ShellEnvironment.loginShellEnvironment`) so a Galaxy session gets
    /// the same environment a terminal does — profile-exported secrets,
    /// the full PATH, locale. Falls back to this process's own
    /// (launchd-minimal) environment if the capture fails, so a session
    /// can always start.
    ///
    /// On top of the base it re-applies Galaxy's existing massaging:
    /// strip vars that interfere with a child session, force a
    /// known-good TERM/LANG, ensure ~/.local/bin is on PATH, and (for
    /// vanilla Claude sessions) inject CLAUDE_CLI_SESSION_ID.
    private static func buildChildEnvironment(
        injectSessionId: Bool,
        sessionId: String
    ) -> [String] {
        // Base: the login shell's environment; fall back to this
        // process's own environment if the capture fails.
        var envArray = ShellEnvironment.loginShellEnvironment()
            ?? ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }

        // Strip environment variables that interfere with child sessions:
        // - TERM/COLORTERM/LANG: overridden below for terminal behavior
        // - CLAUDECODE: set by running Claude Code sessions; if Galaxy.app
        //   was launched from within a Claude session, this prevents child
        //   processes from starting ("nested session" detection)
        // - CLAUDE_CLI_SESSION_ID: set by Claude Persona sessions; if Galaxy.app
        //   was launched from within such a session, the inherited value would
        //   cause ledger hooks to resolve to the parent session instead of this one
        // - CLAUDE_CODE_*: the same hazard from the other direction. Launching
        //   Galaxy.app from inside a Claude Code session — an agent restarting
        //   it with `open` — leaks CLAUDE_CODE_SESSION_ID and
        //   CLAUDE_CODE_CHILD_SESSION in, so a session spawned here would carry
        //   the launching session's identity. The whole family goes, since
        //   CLAUDE_CODE_ENTRYPOINT and CLAUDE_CODE_EXECPATH describe the parent
        //   too
        // - the inherited terminal identity: replaced below with Galaxy's own.
        //   See TerminalIdentity for which entries and why
        envArray = envArray.filter {
            !$0.hasPrefix("TERM=") &&
            !$0.hasPrefix("COLORTERM=") &&
            !$0.hasPrefix("LANG=") &&
            !TerminalIdentity.isInherited($0) &&
            !$0.hasPrefix("CLAUDECODE=") &&
            !$0.hasPrefix("CLAUDE_CLI_SESSION_ID=") &&
            !$0.hasPrefix("CLAUDE_CODE_")
        }
        envArray.append("TERM=xterm-256color")
        envArray.append(TerminalIdentity.declaration)
        // Don't set COLORTERM=truecolor — this makes Claude Code use 24-bit
        // true color RGB values from its own theme, bypassing the ANSI palette.
        // Without it, Claude Code falls back to ANSI indexed colors, which are
        // controlled by our installed palette and match Terminal.app's rendering.
        envArray.append("LANG=en_US.UTF-8")

        // Ensure ~/.local/bin is in PATH. When the login-shell capture
        // succeeds the profile already rebuilds PATH (this is then a
        // no-op); on the fallback path Galaxy.app inherits launchd's
        // minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin),
        // which doesn't include ~/.local/bin where claude-persona
        // resolves `claude` via PATH lookup.
        let localBin = "\(NSHomeDirectory())/.local/bin"
        if let pathIndex = envArray.firstIndex(where: { $0.hasPrefix("PATH=") }) {
            let existing = envArray[pathIndex]
            if !existing.contains(localBin) {
                envArray[pathIndex] = "\(existing):\(localBin)"
            }
        } else {
            envArray.append("PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:\(localBin)")
        }

        // Point non-interactive Bash tool calls at the user's bashrc.
        // Claude Code's Bash tool spawns `bash -c`, which sources a
        // startup file only when BASH_ENV names one. Without it, shell
        // functions defined in ~/.bashrc (version-manager shims, etc.)
        // are unavailable to tool calls — the login-shell environment we
        // captured above carries exported vars and PATH but not shell
        // functions. Set BASH_ENV to ~/.bashrc when that file exists and
        // the captured environment didn't already provide one (never
        // override a user-set value). Computed from NSHomeDirectory(), so
        // nothing is hardcoded to a specific home — correct for any user.
        let bashrc = "\(NSHomeDirectory())/.bashrc"
        let hasBashEnv = envArray.contains { $0.hasPrefix("BASH_ENV=") }
        if !hasBashEnv && FileManager.default.fileExists(atPath: bashrc) {
            envArray.append("BASH_ENV=\(bashrc)")
        }

        // Inject CLAUDE_CLI_SESSION_ID for vanilla Claude sessions so ledger
        // hooks resolve via Tier 1 (env var) instead of Tier 2 (PID). This
        // prevents PID-recycling from cross-linking ledger sessions.
        if injectSessionId {
            envArray.append("CLAUDE_CLI_SESSION_ID=\(sessionId)")
        }

        return envArray
    }

    func processDidExit(exitCode: Int32) {
        DispatchQueue.main.async {
            self.isRunning = false
            self.hasExited = true
            self.exitCode = exitCode

            // Clear turn state — a dead process can't be in a turn.
            if self.isInTurn {
                self.isInTurn = false
                self.turnStartTime = nil
            }

            // A dead process is not ready. Next resume cycle
            // re-arms via session:ready.
            if self.isReady {
                self.isReady = false
            }

            // A dead process owns no running agents. Its rows
            // are swept by the periodic reconcile; this is the
            // superscript catching up now rather than at the
            // next tick, since a session that has visibly
            // exited should not still be advertising work.
            self.runningAgentCount = 0

            // A dead process can't have an active scrollback —
            // the TerminalHostView is being torn down by SwiftUI
            // as part of the hasExited transition. Reset
            // defensively so any subscriber reflects clean state.
            //
            // Cleared from here rather than from the host's teardown because
            // the registry outlives the host across a stop/resume, so a host
            // going away is not evidence the flag should drop.
            self.paneRegistry.setScrollbackOpen(false, kind: .session)

            // Cancel any pending post-turn-end actions (e.g., a
            // queued review-message send waiting on the next turn
            // boundary). Session is dead — no turn will end.
            self.oneShotTurnEndActions.removeAll()

            // Cancel any pending post-ready actions (e.g., a
            // /handoff still waiting on session:ready). Nothing
            // upstream can fire them now and they'd be invalid
            // for any future resumed lifecycle anyway.
            self.pendingReadyActions.removeAll()

            // The inbox is deliberately NOT cleared here, unlike the two
            // stores above, and the difference is what each of them holds.
            // Those are *actions* — closures bound to a lifecycle that has
            // ended, meaningless to run against the next one. The inbox holds
            // *text a person wrote*, whose composing surface was destroyed
            // before it was ever handed over.
            //
            // Discarding it would be the failure this queue exists to prevent,
            // arriving by a different route: a message the reader can never
            // retype, gone without being shown to anyone. Keeping it costs a
            // message arriving into a fresher context than it was written
            // against — visible in the modal, and the reader's to delete. One
            // of those is recoverable and the other is not.

            // Release the backend to free ~32MB scrollback buffer.
            // The view shows StoppedSessionView now, not the terminal.
            self.releaseBackend()
        }
    }

    /// Terminate the Claude process gracefully. Routes through
    /// the backend, which performs the SIGHUP → SIGTERM →
    /// SIGKILL escalation. SIGHUP first because it's the
    /// canonical "terminal hangup" signal — Claude Code,
    /// claude-persona, and vibe sessions all exit cleanly on
    /// SIGHUP and have a chance to flush state; the harder
    /// signals fire only if the process refuses to exit
    /// within bounded grace periods.
    func terminateProcess() {
        guard let backend = backend else {
            NSLog("Session: Cannot terminate - no backend")
            return
        }
        backend.terminateProcess(signal: SIGHUP)
    }
}

// MARK: - AgentInboxHost

/// What the inbox needs from a session, and nothing more.
extension Session: AgentInboxHost {

    /// Whether this session can read a prompt right now.
    ///
    /// Stricter than "not mid-turn", and the last two terms are the reason
    /// Galaxy needs its own answer rather than the sibling app's. A context
    /// reset here is followed by a `/handoff` that waits on `session:ready`,
    /// and a resume is followed by `/galaxy:resume` the same way. Those are
    /// out of the inbox's scope on purpose — they are owed to a lifecycle
    /// rather than to a turn — so the queue has to stand aside until they have
    /// gone, or it races a sequence that must arrive in order.
    ///
    /// `isReady` covers the same ground from the other side: a session that has
    /// spawned but not reported ready is one whose input layer may not exist
    /// yet.
    var canSendNow: Bool {
        isRunning
            && !hasExited
            && !isInTurn
            && isReady
            && !hasPendingReadyActions
    }

    /// Put one unit in front of the agent and report what became of it.
    ///
    /// Routed through `sendCommand` rather than at the backend, so a queued
    /// message inherits everything an automated send already knows: the
    /// readiness wait, the pacing, the trailing space that closes a completion
    /// popup, the harness's own list of commands no acceptance can be reported
    /// for, and the synthetic-turn bookkeeping a context reset needs.
    /// Reimplementing any of that here would be a second copy of the one
    /// function this codebase went to some trouble to have only once.
    func deliver(
        _ unit: AgentInboxUnit,
        accepted: @escaping (Bool) -> Void
    ) {
        SessionSubmit.log(
            "inbox delivering \(unit.entryIDs.count) "
                + "entr\(unit.entryIDs.count == 1 ? "y" : "ies") "
                + "session=\(sessionRef) retry=\(unit.retry)")

        sendCommand(
            unit.body,
            retry: unit.retry,
            outcome: { outcome in
                switch outcome {
                case .accepted:
                    accepted(true)
                case .unverifiable:
                    // No report was ever possible for this send, so waiting
                    // for one and retrying would only ever produce a
                    // duplicate. The entry has done all it can and leaves.
                    accepted(true)
                case .unconfirmed, .abandoned:
                    accepted(false)
                }
            })
    }
}
