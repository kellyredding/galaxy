import Foundation
import AppKit
import Combine
import SwiftTerm

class Session: Identifiable, ObservableObject {
    /// Delay between sending command text and CR when invoking slash commands.
    /// Without this delay, the text and CR can get batched together, causing
    /// Ink (Claude Code's TUI framework) to not recognize the CR as a submit action.
    private static let commandSubmitDelay: TimeInterval = 0.1  // 100ms

    /// How long to wait after sending CR before checking if it was accepted.
    /// If isInTurn hasn't transitioned to true within this window (driven
    /// by the on_user_prompt_submit hook event), the CR was likely
    /// swallowed and needs to be resent.
    private static let commandVerifyDelay: TimeInterval = 0.25  // 250ms

    /// Maximum number of CR resend attempts before giving up. Each retry
    /// adds one commandVerifyDelay to the total wait. With 2 retries the
    /// worst-case total is: commandSubmitDelay + 3 × commandVerifyDelay = 850ms.
    private static let commandMaxRetries: Int = 2

    /// UUID used for SwiftUI Identifiable AND as Claude's session ID
    let id: UUID

    /// Human-readable session reference for display (e.g., "rich-grass-hides")
    let sessionRef: String

    /// User-assigned name for this session. Galaxy-only — not shared with ledger.
    /// When set, displayName shows "givenName (sessionRef)".
    @Published var givenName: String?

    /// Display string for user-facing contexts (sidebar, menu, stopped screen).
    ///
    /// Three-state givenName logic:
    /// - givenName is non-empty string → "givenName (sessionRef)"
    /// - givenName is nil + suggested name exists → "suggestedName (sessionRef)"
    /// - givenName is nil + no suggested name → bare sessionRef
    /// - givenName is "" (explicitly cleared) → bare sessionRef
    var displayName: String {
        if let name = givenName, !name.isEmpty {
            return "\(name) (\(sessionRef))"
        }
        if givenName == nil, let suggested = ledgerSuggestedName, !suggested.isEmpty {
            return "\(suggested) (\(sessionRef))"
        }
        return sessionRef
    }

    @Published var isRunning: Bool = false
    @Published var hasExited: Bool = false
    @Published var exitCode: Int32?
    /// True when the session was stopped by the user (stop button, ⌘W).
    /// Prevents "exited unexpectedly" notifications for intentional stops.
    var userInitiatedStop: Bool = false
    /// Whether this session has an unread response the user hasn't seen yet.
    /// Set by SessionManager.handleIdleTransition when a non-focused session
    /// goes idle. Cleared when the user views the session on the terminal tab.
    ///
    /// Two display surfaces read this state independently:
    /// - Sidebar/tab red dots (gated by showUnreadIndicator setting)
    /// - Dock badge count (gated by showDockBadge setting)
    ///
    /// IMPORTANT: After mutating this property, call
    /// SessionManager.shared.updateDockBadge() to keep the dock badge in sync.
    @Published var hasUnreadResponse: Bool = false
    @Published var visualBellActive: Bool = false

    /// Gate for bell-pipeline debounce. Set true at the top of
    /// the bell handler while a bell event is in progress;
    /// additional bells that arrive during this window are
    /// dropped entirely — no sound, no flash, no notification.
    /// Window duration matches the full visual flash sequence
    /// (~1.225s) so the debounce naturally aligns with the
    /// perceived bell event.
    @Published var bellDebounceActive: Bool = false

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
    /// Reset to false on `startProcess`, `releaseTerminalView`,
    /// and `processDidExit` so each new lifecycle starts unready.
    @Published private(set) var isReady: Bool = false

    /// True when this session's terminal pane has its scrollback
    /// overlay open. Updated by the session pane's
    /// TerminalHostView in createScrollback /
    /// performScrollbackTeardown. Read by the shell pane's
    /// send-to-claude target to gate the cross-pane send button —
    /// sending into a paused buffer view would land out of order.
    /// Source-of-truth lives on Session (not on the
    /// TerminalHostView itself) so subscribers survive stop/resume
    /// cycles, which destroy and recreate the host NSView.
    /// Reset to false in processDidExit so a future resumed
    /// lifecycle starts with a clean signal.
    @Published private(set) var sessionPaneScrollbackActive: Bool
        = false

    /// Setter exposed for TerminalHostView, which is the only
    /// legitimate writer. Call from the session pane's overlay
    /// open/close code paths.
    func setSessionPaneScrollbackActive(_ active: Bool) {
        sessionPaneScrollbackActive = active
    }

    /// Number of currently running agents. Maintained by
    /// EventCoordinator (increment on agent:started, decrement
    /// on agent:stopped/failed/abandoned). Seeded at startup
    /// via CLI query. Corrected when AgentsView fetches.
    @Published var runningAgentCount: Int = 0

    /// When the current turn started (startTurn called).
    /// Used to compute turn duration for notification/unread gates.
    private var turnStartTime: Date?

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

    /// Which terminal pane a scrollback checker covers.
    /// Stop-session and quit-app each consult a different
    /// subset — stopping a session only loses notes from
    /// the session pane (the shell process survives),
    /// while quitting the app loses both. Tagging the
    /// registered checker is what lets callers ask the
    /// right question.
    enum ScrollbackPaneKind {
        case session
        case shell
    }

    /// Per-host-view closures that check whether this
    /// session has unsaved scrollback work (notes, form
    /// content, in-progress edits). Keyed by the
    /// registering `TerminalHostView`'s
    /// `ObjectIdentifier` so multiple panes each
    /// contribute one checker; dying views remove theirs
    /// cleanly. Each entry carries a
    /// `ScrollbackPaneKind` so callers can filter to the
    /// panes whose loss matters in their context. Use
    /// `registerScrollbackUnsavedWorkChecker` /
    /// `unregisterScrollbackUnsavedWorkChecker` /
    /// `checkAnyScrollbackUnsavedWork` — do not access
    /// directly.
    private var scrollbackUnsavedWorkCheckers:
        [ObjectIdentifier: (
            kind: ScrollbackPaneKind,
            check: (@escaping (Bool) -> Void) -> Void
        )] = [:]

    /// Register a checker for one pane's scrollback.
    /// Call from `TerminalHostView` setup with the kind
    /// that matches the host view's pane.
    func registerScrollbackUnsavedWorkChecker(
        _ key: ObjectIdentifier,
        kind: ScrollbackPaneKind,
        checker: @escaping (
            @escaping (Bool) -> Void
        ) -> Void
    ) {
        scrollbackUnsavedWorkCheckers[key] =
            (kind: kind, check: checker)
    }

    /// Remove a checker when its host view goes away.
    func unregisterScrollbackUnsavedWorkChecker(
        _ key: ObjectIdentifier
    ) {
        scrollbackUnsavedWorkCheckers
            .removeValue(forKey: key)
    }

    /// Fan out to checkers matching `kinds` and report
    /// `true` if ANY of them reports unsaved work. Runs
    /// the per-pane checks in parallel. Calls completion
    /// on main.
    ///
    /// Stop-session uses `[.session]` — shell pane notes
    /// don't matter because the shell process keeps
    /// running. Quit-app uses `[.session, .shell]` for
    /// live sessions and `[.shell]` for stopped sessions
    /// (whose shell pane may still be open).
    func checkAnyScrollbackUnsavedWork(
        kinds: Set<ScrollbackPaneKind>,
        completion: @escaping (Bool) -> Void
    ) {
        let entries = scrollbackUnsavedWorkCheckers.values
            .filter { kinds.contains($0.kind) }
        guard !entries.isEmpty else {
            completion(false)
            return
        }

        let group = DispatchGroup()
        var anyHasWork = false
        let lock = NSLock()

        for entry in entries {
            group.enter()
            entry.check { hasWork in
                if hasWork {
                    lock.lock()
                    anyHasWork = true
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(anyHasWork)
        }
    }

    // MARK: - Pane Focus Memory

    /// Which pane was most recently the first responder. Read
    /// by tab-switch / session-switch / window-becomes-key
    /// restoration paths so the user lands back on whichever
    /// pane they were last typing in. Written by
    /// `TerminalHostView` when its inner view gains first
    /// responder. Defaults to `.session` so single-pane
    /// sessions (no shell open) behave identically to before.
    @Published var lastFocusedPaneKind:
        ScrollbackPaneKind = .session

    /// Per-host restoration closures, keyed by registering
    /// `TerminalHostView`'s `ObjectIdentifier`. Each entry
    /// carries its `ScrollbackPaneKind` so
    /// `restorePreferredPaneFocus` can pick the one matching
    /// `lastFocusedPaneKind`. Mirrors
    /// `scrollbackUnsavedWorkCheckers` so registration /
    /// unregistration / lookup follow the same shape.
    private var paneFocusRestorers:
        [ObjectIdentifier: (
            kind: ScrollbackPaneKind,
            restore: () -> Void
        )] = [:]

    /// Register a pane focus restorer. Call from
    /// `TerminalHostView` setup. Paired with
    /// `unregisterPaneFocusRestorer` in deinit.
    func registerPaneFocusRestorer(
        _ key: ObjectIdentifier,
        kind: ScrollbackPaneKind,
        restore: @escaping () -> Void
    ) {
        paneFocusRestorers[key] = (kind: kind, restore: restore)
    }

    /// Remove a restorer when its host view goes away.
    func unregisterPaneFocusRestorer(
        _ key: ObjectIdentifier
    ) {
        paneFocusRestorers.removeValue(forKey: key)
    }

    /// Restore focus to the pane matching
    /// `lastFocusedPaneKind`, falling back to whichever pane
    /// is registered if the preferred one isn't available
    /// (e.g., user remembered being in shell, but the shell
    /// pane has since closed). No-op if no panes are
    /// registered.
    func restorePreferredPaneFocus() {
        let preferred = lastFocusedPaneKind
        if let entry = paneFocusRestorers.values
            .first(where: { $0.kind == preferred }) {
            entry.restore()
            return
        }
        // Preferred kind not available — fall back to whatever
        // is registered. Session pane wins ties since that's
        // the historical default.
        if let entry = paneFocusRestorers.values
            .first(where: { $0.kind == .session }) {
            entry.restore()
            return
        }
        if let entry = paneFocusRestorers.values
            .first(where: { $0.kind == .shell }) {
            entry.restore()
        }
    }

    /// Ledger session ID for fast event matching. Set when the event
    /// system first matches this session via session_identifiers array.
    /// Optional because it's not known until the first event or
    /// enrichment call.
    var ledgerSessionId: Int64?

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

    /// Expected direct child process name for PID tracking
    /// "claude-persona" for persona sessions, "claude" for vanilla sessions
    var expectedProcessName: String {
        personaName != nil ? "claude-persona" : "claude"
    }

    /// One-shot closures fired on the next endTurn() call, then
    /// cleared. Used by post-turn workflows (e.g. snapshot/artifact
    /// review-message send after a /galaxy:resume turn completes).
    /// Lifetime is bounded by session death (processDidExit clears)
    /// and by context-reset events (sendCommand for /clear and
    /// /compact clears, since reset invalidates anything queued
    /// against the prior lifecycle).
    private var oneShotTurnEndActions: [() -> Void] = []

    /// Current terminal font size for this session (transient, not persisted)
    @Published var terminalFontSize: CGFloat {
        didSet {
            applyTerminalFontSize()
        }
    }

    /// The GalaxyTerminalView backing this session. Published so
    /// SessionManager can observe lifecycle transitions (creation in
    /// `init`/`ensureTerminalView`, teardown in `releaseTerminalView`)
    /// and re-wire its callbacks without duplicating setup code at
    /// every call site. See `SessionManager.observeTerminalViewLifecycle`.
    @Published private(set) var terminalView: GalaxyTerminalView?
    let createdAt: Date
    let workingDirectory: String

    // Keep a strong reference to the process handler so it doesn't get deallocated
    var processHandler: TerminalProcessHandler?

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

    // Track the child process PID for termination (SwiftTerm doesn't expose this)
    private var childPid: pid_t = 0

    init(workingDirectory: String, sessionRef: String, personaName: String? = nil, isVibe: Bool = false, resumeSessionId: UUID? = nil) {
        // Use provided resume UUID if resuming a specific session, otherwise generate new
        self.id = resumeSessionId ?? UUID()
        self.sessionRef = sessionRef
        self.personaName = personaName
        self.isVibe = isVibe
        self.claudeSessionId = self.id.uuidString.lowercased()
        self.createdAt = Date()
        self.workingDirectory = workingDirectory

        // Initialize terminal font size from settings default
        self.terminalFontSize = SettingsManager.shared.settings.defaultTerminalFontSize

        // Create terminal view with default configuration
        self.terminalView = GalaxyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        configureTerminal()
        applyScrollbackSize()
    }

    private func configureTerminal() {
        guard let terminalView = terminalView else { return }

        // Disable custom block glyph rendering so block elements (U+2580-U+259F)
        // and box drawing (U+2500-U+257F) fall through to CoreText font rendering.
        // This lets the system font fallback produce glyphs that match Terminal.app.
        terminalView.customBlockGlyphs = false

        // Apply color theme from settings
        applyColorTheme()

        // Apply initial font
        applyTerminalFontSize()

        // Re-apply font when the font family setting changes.
        // Stored in terminalCancellables so releaseTerminalView() can cancel
        // these independently without affecting non-terminal subscriptions.
        SettingsManager.shared.$settings
            .map(\.terminalFontFamily)
            .removeDuplicates()
            .dropFirst()  // Skip initial value (already applied above)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyTerminalFontSize()
            }
            .store(in: &terminalCancellables)

        // Observe color theme changes
        SettingsManager.shared.$settings
            .map(\.terminalColorThemeName)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyColorTheme()
            }
            .store(in: &terminalCancellables)

        // Observe scrollback size changes
        SettingsManager.shared.$settings
            .map(\.terminalScrollbackLines)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyScrollbackSize()
            }
            .store(in: &terminalCancellables)
    }

    /// Apply the selected color theme to the terminal view.
    private func applyColorTheme() {
        guard let terminalView = terminalView else { return }
        let theme = TerminalColorTheme.theme(
            named: SettingsManager.shared.settings.terminalColorThemeName
        )
        terminalView.nativeForegroundColor = theme.foregroundColor
        terminalView.nativeBackgroundColor = theme.backgroundColorValue
        terminalView.installColors(theme.swiftTermPalette)
        terminalView.galaxyBoldForegroundColor = theme.boldForegroundColor
        NSLog("Session[%@]: Applied color theme '%@'", sessionRef, theme.name)
    }

    /// Apply the current terminal font to the terminal view
    private func applyTerminalFontSize() {
        guard let terminalView = terminalView else { return }
        let family = SettingsManager.shared.settings.terminalFontFamily
        let font: NSFont
        if family == "SF Mono" {
            // SF Mono is only available via the system monospaced font API.
            // .medium weight matches Terminal.app's rendering more closely than .regular,
            // which Apple maps to an unexpectedly light weight for this font.
            font = NSFont.monospacedSystemFont(ofSize: terminalFontSize, weight: .medium)
        } else {
            font = NSFont(name: family, size: terminalFontSize)
                ?? NSFont.monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
        }
        NSLog("Session[%@]: applyFont family=%@ -> fontName=%@ size=%.0f", sessionRef, family, font.fontName, terminalFontSize)
        terminalView.font = font
    }

    /// Apply the scrollback buffer size from settings to the terminal view.
    /// Uses SwiftTerm's changeHistorySize() which supports runtime changes —
    /// increasing preserves existing history, decreasing trims oldest lines.
    private func applyScrollbackSize() {
        guard let terminalView = terminalView else { return }
        let lines = SettingsManager.shared.settings.terminalScrollbackLines
        terminalView.terminal.changeHistorySize(lines)
        NSLog("Session[%@]: Applied scrollback size %d lines", sessionRef, lines)
    }

    /// Create the terminal view if it doesn't exist yet.
    /// Called by SessionManager before resuming a stopped session.
    /// Runs full configuration (theme, font, scrollback, observers).
    func ensureTerminalView() {
        guard terminalView == nil else { return }
        terminalView = GalaxyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        configureTerminal()
        applyScrollbackSize()
        NSLog("Session[%@]: Created terminal view on demand", sessionRef)
    }

    /// Release the terminal view to free memory (~32MB scrollback buffer).
    /// Called after a session exits and the terminal is no longer needed.
    /// Safe to call multiple times. A subsequent ensureTerminalView()
    /// will recreate everything.
    ///
    /// Does NOT call removeFromSuperview() — SwiftUI manages the view
    /// hierarchy. The TerminalHostView holds its own strong reference
    /// and releases it when SwiftUI tears down the FocusableTerminalView
    /// during the hasExited transition.
    func releaseTerminalView() {
        guard terminalView != nil else { return }

        // Clear callbacks to break any retain cycles
        terminalView?.onBell = nil
        terminalView?.processDelegate = nil

        // Clear readiness — a future ensureTerminalView() +
        // startProcess() cycle will re-arm via session:ready.
        isReady = false

        // Release the view — TerminalHostView retains its own copy
        // until SwiftUI tears it down via the hasExited transition.
        terminalView = nil

        // Cancel terminal-specific Combine subscriptions only.
        // ensureTerminalView() will re-subscribe via configureTerminal().
        // Uses a dedicated set so non-terminal subscriptions in
        // cancellables are unaffected.
        terminalCancellables.removeAll()

        // Clear process handler reference
        processHandler = nil

        NSLog("Session[%@]: Released terminal view", sessionRef)
    }

    /// Increase terminal font size by one step
    func increaseTerminalFontSize() {
        let newSize = min(terminalFontSize + AppSettings.terminalFontSizeStep, AppSettings.terminalFontSizeRange.upperBound)
        terminalFontSize = newSize
    }

    /// Decrease terminal font size by one step
    func decreaseTerminalFontSize() {
        let newSize = max(terminalFontSize - AppSettings.terminalFontSizeStep, AppSettings.terminalFontSizeRange.lowerBound)
        terminalFontSize = newSize
    }

    /// Check if terminal font size can be increased
    var canIncreaseTerminalFontSize: Bool {
        terminalFontSize < AppSettings.terminalFontSizeRange.upperBound
    }

    /// Check if terminal font size can be decreased
    var canDecreaseTerminalFontSize: Bool {
        terminalFontSize > AppSettings.terminalFontSizeRange.lowerBound
    }

    /// Reset terminal font size to the default from settings
    func resetTerminalFontSize() {
        terminalFontSize = SettingsManager.shared.settings.defaultTerminalFontSize
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
    /// By default, uses a verify-and-retry loop: after sending the CR,
    /// checks whether the session transitioned to busy (meaning Claude
    /// accepted the command). If not, resends the CR up to
    /// `commandMaxRetries` times. This eliminates the timing-only
    /// approach where a single blind delay could still lose the CR on
    /// loaded systems.
    ///
    /// Pass `verifyAccepted: false` when the caller has independent
    /// confirmation that Claude is at the prompt and ready to receive
    /// input (e.g., the `session:ready` hook event after resume). The
    /// retry path can be actively harmful on slash commands like
    /// `/galaxy:resume` whose initial work (skill load + tool calls)
    /// often takes longer than the 250ms verify window — a stray
    /// retry CR ends up buffered at the kernel TTY input, then
    /// dequeued at the empty prompt after the first command finishes,
    /// where Claude Code's TUI interprets Enter-on-empty as
    /// "repeat last command" and re-runs the command.
    /// Detect /clear and /compact, which bypass Claude
    /// Code's UserPromptSubmit hook (handled at the TUI
    /// level before the prompt-submit pipeline runs).
    /// `sendCommand` treats matches as synthetic Galaxy-
    /// initiated turns, optimistically calling startTurn
    /// since no turn:initiated socket event will arrive.
    private static func isContextResetCommand(
        _ command: String
    ) -> Bool {
        let trimmed = command.trimmingCharacters(
            in: .whitespaces
        )
        return trimmed == "/clear" || trimmed == "/compact"
    }

    func sendCommand(
        _ command: String, verifyAccepted: Bool = true
    ) {
        guard isRunning && !hasExited else {
            NSLog("Session: Cannot send command - session not running")
            return
        }

        NSLog("Session: Sending command: %@", command)

        // Capture pre-send turn state. If we're already in a turn,
        // the on_user_prompt_submit hook's turn:initiated event
        // can't serve as a CR-acceptance signal (isInTurn is
        // already true), so skip verification and fall back to
        // fire-and-forget.
        let wasInTurn = isInTurn

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
        if Self.isContextResetCommand(command) {
            startTurn(source: "sendCommand:\(command)")
            isReady = false
            pendingReadyActions.removeAll()
            oneShotTurnEndActions.removeAll()
        }

        // Send command text first
        terminalView?.send(txt: command)

        // Small delay to ensure text is processed before CR
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandSubmitDelay) { [weak self] in
            guard let self = self, self.isRunning, !self.hasExited else { return }

            // Send CR (0x0D) - same byte as keyboard Return
            self.terminalView?.send([0x0D])

            // Skip verification if caller opted out, or if session
            // was already in a turn when we entered.
            guard verifyAccepted, !wasInTurn else { return }

            self.verifyCommandSubmit(retriesLeft: Self.commandMaxRetries)
        }
    }

    /// Check whether the session entered a turn after sending CR.
    /// If not, resend CR and schedule another check. Bails after
    /// exhausting retries. Detection rides on isInTurn, which is
    /// flipped by the on_user_prompt_submit hook event — a true
    /// "Claude received the prompt" signal.
    private func verifyCommandSubmit(retriesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandVerifyDelay) { [weak self] in
            guard let self = self, self.isRunning, !self.hasExited else { return }

            if self.isInTurn {
                NSLog("Session: Command accepted (retries remaining: %d)", retriesLeft)
                return
            }

            if retriesLeft <= 0 {
                NSLog("Session: Command CR retries exhausted — giving up")
                return
            }

            NSLog("Session: Command CR not accepted, resending (%d retries left)", retriesLeft)
            self.terminalView?.send([0x0D])
            self.verifyCommandSubmit(retriesLeft: retriesLeft - 1)
        }
    }

    // MARK: - Turn State (socket-driven)

    /// Called when a turn-start signal arrives (socket
    /// turn:initiated event, or sendCommand). Sets
    /// isInTurn and fires the onTurnStart callback.
    func startTurn(source: String = "unknown") {
        guard !isInTurn else { return }
        GalaxyLog.events(
            "[\(sessionRef)] TurnState:"
            + " startTurn() source=\(source)"
        )
        isInTurn = true
        turnStartTime = Date()
        onTurnStart?(self)
    }

    /// Called when an authoritative turn-end signal
    /// arrives (socket event). Clears turn state and
    /// fires the onTurnEnd callback with the turn's
    /// duration.
    func endTurn(source: String = "unknown") {
        GalaxyLog.events(
            "[\(sessionRef)] TurnState: endTurn()"
            + " source=\(source)"
            + " wasInTurn=\(isInTurn)"
        )
        guard isInTurn else { return }
        isInTurn = false

        let duration = turnStartTime.map {
            Date().timeIntervalSince($0)
        }
        turnStartTime = nil

        // Drain one-shot post-turn actions. Drain BEFORE
        // calling them so the source array is empty before
        // any action runs — protects against an action that
        // re-enters endTurn or re-registers a new one-shot.
        if !oneShotTurnEndActions.isEmpty {
            let actions = oneShotTurnEndActions
            oneShotTurnEndActions.removeAll()
            for action in actions {
                action()
            }
        }

        onTurnEnd?(self, duration)
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
    /// `releaseTerminalView`, `processDidExit`, and
    /// inside `sendCommand` for context-reset commands.
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
    /// state with no terminal view and no running process.
    /// Terminal is lazily created by ensureTerminalView() on resume.
    init(restoring state: PersistedSession) {
        self.id = state.id
        self.sessionRef = state.sessionRef
        self.claudeSessionId = state.claudeSessionId
        self.createdAt = state.createdAt
        self.workingDirectory = state.workingDirectory
        self.personaName = state.personaName
        self.isVibe = state.isVibe
        self.terminalFontSize = SettingsManager.shared
            .settings.defaultTerminalFontSize

        // No terminal view — stopped sessions don't need one.
        // ensureTerminalView() creates it on resume.
        self.terminalView = nil

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
        // Build environment as array of "KEY=VALUE" strings
        var envArray: [String] = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }

        // Strip environment variables that interfere with child sessions:
        // - TERM/COLORTERM/LANG: overridden below for terminal behavior
        // - CLAUDECODE: set by running Claude Code sessions; if Galaxy.app
        //   was launched from within a Claude session, this prevents child
        //   processes from starting ("nested session" detection)
        // - CLAUDE_CLI_SESSION_ID: set by Claude Persona sessions; if Galaxy.app
        //   was launched from within such a session, the inherited value would
        //   cause ledger hooks to resolve to the parent session instead of this one
        envArray = envArray.filter {
            !$0.hasPrefix("TERM=") &&
            !$0.hasPrefix("COLORTERM=") &&
            !$0.hasPrefix("LANG=") &&
            !$0.hasPrefix("CLAUDECODE=") &&
            !$0.hasPrefix("CLAUDE_CLI_SESSION_ID=")
        }
        envArray.append("TERM=xterm-256color")
        // Don't set COLORTERM=truecolor — this makes Claude Code use 24-bit
        // true color RGB values from its own theme, bypassing the ANSI palette.
        // Without it, Claude Code falls back to ANSI indexed colors, which are
        // controlled by our installed palette and match Terminal.app's rendering.
        envArray.append("LANG=en_US.UTF-8")

        // Ensure ~/.local/bin is in PATH. Galaxy.app inherits launchd's
        // minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin)
        // which doesn't include ~/.local/bin. Child processes like
        // claude-persona need to find `claude` via PATH lookup.
        let localBin = "\(NSHomeDirectory())/.local/bin"
        if let pathIndex = envArray.firstIndex(where: { $0.hasPrefix("PATH=") }) {
            let existing = envArray[pathIndex]
            if !existing.contains(localBin) {
                envArray[pathIndex] = "\(existing):\(localBin)"
            }
        } else {
            envArray.append("PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:\(localBin)")
        }

        // Build args and determine executable
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

            // Inject CLAUDE_CLI_SESSION_ID into process environment so ledger
            // hooks resolve via Tier 1 (env var) instead of Tier 2 (PID).
            // This prevents PID-recycling from cross-linking ledger sessions.
            // Persona sessions get this via claude-persona's --settings mechanism.
            envArray.append("CLAUDE_CLI_SESSION_ID=\(claudeSessionId)")
        }

        // Start process directly (not via shell) so SwiftTerm can properly monitor it
        // SwiftTerm 1.10+ supports currentDirectory parameter directly
        guard let terminalView = terminalView else {
            NSLog("Session: Cannot start process - no terminal view")
            return
        }
        // Reset readiness — each new lifecycle starts unready.
        // The on_resume / on_startup hook will emit
        // `session:ready` once it completes, flipping this back
        // to true via markReady().
        isReady = false

        terminalView.startProcess(
            executable: executablePath,
            args: args,
            environment: envArray,
            execName: execName,
            currentDirectory: workingDirectory
        )

        isRunning = true
        NSLog("Session: Started process for %@ in %@", sessionRef, workingDirectory)

        // Capture the child PID after a short delay to allow fork to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.captureChildPid()
        }
    }

    func processDidExit(exitCode: Int32) {
        DispatchQueue.main.async {
            self.isRunning = false
            self.hasExited = true
            self.exitCode = exitCode
            self.childPid = 0

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

            // A dead process can't have an active scrollback —
            // the TerminalHostView is being torn down by SwiftUI
            // as part of the hasExited transition. Reset
            // defensively so any subscriber reflects clean state.
            if self.sessionPaneScrollbackActive {
                self.sessionPaneScrollbackActive = false
            }

            // Cancel any pending post-turn-end actions (e.g., a
            // queued review-message send waiting on the next turn
            // boundary). Session is dead — no turn will end.
            self.oneShotTurnEndActions.removeAll()

            // Cancel any pending post-ready actions (e.g., a
            // /handoff still waiting on session:ready). Nothing
            // upstream can fire them now and they'd be invalid
            // for any future resumed lifecycle anyway.
            self.pendingReadyActions.removeAll()

            // Release terminal view to free ~32MB scrollback buffer.
            // The view shows StoppedSessionView now, not the terminal.
            self.releaseTerminalView()
        }
    }

    /// Terminate the child process gracefully
    /// Tries SIGHUP first (terminal hangup), falls back to SIGTERM if needed
    func terminateProcess() {
        guard childPid > 0 else {
            NSLog("Session: Cannot terminate - no child PID tracked")
            return
        }

        let pid = childPid

        // First try SIGHUP (graceful terminal hangup)
        NSLog("Session: Sending SIGHUP to PID %d", pid)
        kill(pid, SIGHUP)

        // Check after a short delay if process is still running
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            // kill with signal 0 just checks if process exists
            if kill(pid, 0) == 0 {
                // Process still running, escalate to SIGTERM
                NSLog("Session: Process %d still running after SIGHUP, sending SIGTERM", pid)
                kill(pid, SIGTERM)
            } else {
                NSLog("Session: Process %d terminated after SIGHUP", pid)
            }
        }
    }

    /// Find the direct child process that belongs to this session
    /// Uses expectedProcessName to target "claude-persona" for persona sessions
    /// or "claude" for vanilla sessions.
    func captureChildPid() {
        let processName = expectedProcessName
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // -P: parent PID, -n: newest match, -x: exact name match
        task.arguments = ["-P", String(getpid()), "-n", "-x", processName]

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(output), pid > 0 {
                self.childPid = pid
                NSLog("Session: Captured child PID %d for %@", pid, sessionRef)
            } else {
                NSLog("Session: Could not find child PID for %@", sessionRef)
            }
        } catch {
            NSLog("Session: Error running pgrep: %@", error.localizedDescription)
        }
    }
}
