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
    /// If isBusy hasn't transitioned to true within this window, the CR was
    /// likely swallowed and needs to be resent.
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
    @Published var isBusy: Bool = false

    // MARK: - Turn State
    //
    // Socket-driven turn model (Phase 3):
    // - isBusy (micro): PTY activity toggle with 500ms debounce.
    //   Drives: sendCommand CR verification, resume startup
    //   detection (afterNextIdle), interrupt detection
    //   (checkForInterrupt on micro-idle). Does NOT touch isInTurn.
    // - isInTurn (turn): exclusively socket-driven via
    //   startTurn/endTurn. Set by timeline.turn:initiated socket
    //   event or sendCommand(). Cleared by turn-end socket events
    //   (completed/failed/continued/interrupted). All user-visible
    //   consumers observe isInTurn.

    /// True when the session is in an active turn (Claude is
    /// working). Set by startTurn() (socket event or
    /// sendCommand), cleared by endTurn() (socket event).
    /// All user-visible consumers observe this, not isBusy.
    @Published var isInTurn: Bool = false

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

    // MARK: - Ledger Enrichment Data
    // Populated by EventCoordinator.applyEnrichmentData() on each
    // session.metrics event. Plain var (not @Published) until a
    // specific property is promoted for UI rendering.

    /// Closure set by TerminalHostView to check whether scrollback
    /// has unsaved work (notes, form content, or in-progress edits).
    /// Called by SessionManager before stopping a session.
    var checkScrollbackUnsavedWork:
        ((@escaping (Bool) -> Void) -> Void)?

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

    /// Debounce timer for busy→idle transition
    private var busyDebounceTimer: Timer?

    /// How long after the last PTY output before transitioning busy→idle
    private static let busyDebounceInterval: TimeInterval = 0.5

    /// One-shot closures to fire on the next busy→idle transition.
    /// Armed when the session transitions idle→busy after being set.
    /// Fired and cleared on the subsequent busy→idle transition.
    private var afterNextIdleActions: [() -> Void] = []

    /// Whether the afterNextIdle actions have been armed (session went
    /// busy after they were registered). Prevents firing on a stale
    /// idle transition that was already in progress when actions were set.
    private var afterNextIdleArmed: Bool = false

    /// Persistent callback fired on every busy→idle transition.
    /// Narrowed to interrupt detection only — all other consumers
    /// moved to onTurnEnd.
    var onIdleTransition: ((Session) -> Void)?

    /// Current terminal font size for this session (transient, not persisted)
    @Published var terminalFontSize: CGFloat {
        didSet {
            applyTerminalFontSize()
        }
    }

    private(set) var terminalView: GalaxyTerminalView?
    let createdAt: Date
    let workingDirectory: String

    // Keep a strong reference to the process handler so it doesn't get deallocated
    var processHandler: TerminalProcessHandler?

    private var cancellables = Set<AnyCancellable>()
    private var terminalCancellables = Set<AnyCancellable>()

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

        // Stop content monitor before clearing callbacks
        terminalView?.stopContentMonitor()

        // Clear callbacks to break any retain cycles
        terminalView?.onBell = nil
        terminalView?.onDataReceived = nil
        terminalView?.processDelegate = nil

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
    /// Uses a verify-and-retry loop: after sending the CR, checks whether
    /// the session transitioned to busy (meaning Claude accepted the
    /// command). If not, resends the CR up to `commandMaxRetries` times.
    /// This eliminates the timing-only approach where a single blind delay
    /// could still lose the CR on loaded systems.
    func sendCommand(_ command: String) {
        guard isRunning && !hasExited else {
            NSLog("Session: Cannot send command - session not running")
            return
        }

        NSLog("Session: Sending command: %@", command)

        // Galaxy-initiated turn — enter immediately.
        // The hook's turn:initiated socket event will arrive
        // as a redundant no-op (startTurn guards on !isInTurn).
        startTurn(source: "sendCommand:\(command)")

        // If already busy we can't use isBusy as a verification signal.
        // Fall back to the original fire-and-forget behavior.
        let wasBusy = isBusy

        // Send command text first
        terminalView?.send(txt: command)

        // Small delay to ensure text is processed before CR
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandSubmitDelay) { [weak self] in
            guard let self = self, self.isRunning, !self.hasExited else { return }

            // Send CR (0x0D) - same byte as keyboard Return
            self.terminalView?.send([0x0D])

            // Skip verification if session was already busy
            guard !wasBusy else { return }

            self.verifyCommandSubmit(retriesLeft: Self.commandMaxRetries)
        }
    }

    /// Check whether the session went busy after sending CR. If not,
    /// resend CR and schedule another check. Bails after exhausting retries.
    private func verifyCommandSubmit(retriesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandVerifyDelay) { [weak self] in
            guard let self = self, self.isRunning, !self.hasExited else { return }

            if self.isBusy {
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

    // MARK: - Busy State (micro-level)
    //
    // Tracks PTY activity with a 500ms debounce.
    // Does NOT drive turn state (isInTurn) — that's
    // socket-driven via startTurn/endTurn.
    //
    // Consumers:
    // - sendCommand CR verification (needs sub-250ms
    //   signal that PTY output started)
    // - Resume startup detection (afterNextIdle needs
    //   a busy→idle cycle to detect transcript restore
    //   completion)
    // - Interrupt detection (checkForInterrupt runs on
    //   every micro-idle via onIdleTransition)

    /// Called from onDataReceived callback.
    func markBusy() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.isRunning, !self.hasExited
            else { return }

            if !self.isBusy {
                self.isBusy = true
            }

            self.busyDebounceTimer?.invalidate()
            self.busyDebounceTimer = Timer
                .scheduledTimer(
                    withTimeInterval:
                        Self.busyDebounceInterval,
                    repeats: false
                ) { [weak self] _ in
                    guard let self = self else {
                        return
                    }
                    self.isBusy = false
                    self.onIdleTransition?(self)
                }
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

        // Arm pending one-shot actions
        if !afterNextIdleActions.isEmpty {
            afterNextIdleArmed = true
        }
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

        // Fire armed one-shot actions (afterNextIdle)
        if afterNextIdleArmed,
           !afterNextIdleActions.isEmpty
        {
            let actions = afterNextIdleActions
            afterNextIdleActions.removeAll()
            afterNextIdleArmed = false
            for action in actions {
                action()
            }
        }

        onTurnEnd?(self, duration)
    }

    /// Register a one-shot action to fire after the next complete
    /// busy→idle cycle. Multiple actions can be queued; all fire
    /// together. If the session is already in a turn, the action
    /// arms immediately so it fires when that turn ends. If idle,
    /// arming is deferred to the next startTurn call, preventing
    /// premature fires on stale idle state.
    func afterNextIdle(_ action: @escaping () -> Void) {
        afterNextIdleActions.append(action)
        if isInTurn {
            afterNextIdleArmed = true
        }
    }

    // Terminal marker emitted by the on_resume hook after
    // transcript restore completes. SwiftTerm renders
    // inter-word spaces as null bytes (U+0000), so match
    // on the contiguous portion before the first space.
    private static let resumeMarker =
        "SessionStart:resume"

    /// Poll interval and attempt limit for resume marker scan.
    private static let resumeMarkerPollInterval:
        TimeInterval = 0.25
    private static let resumeMarkerMaxAttempts = 40  // 10s

    /// Polls the terminal buffer for the resume marker,
    /// then calls the completion handler. The on_resume hook
    /// prints this marker once Claude has restored the
    /// transcript and processed startup hooks — meaning the
    /// prompt is ready (or nearly ready) for input.
    func waitForResumeMarker(
        then action: @escaping () -> Void
    ) {
        var attempts = 0
        Timer.scheduledTimer(
            withTimeInterval: Self.resumeMarkerPollInterval,
            repeats: true
        ) { [weak self] timer in
            attempts += 1
            guard let self = self else {
                timer.invalidate()
                return
            }
            if self.bufferContainsResumeMarker() {
                timer.invalidate()
                action()
                return
            }
            if attempts >= Self.resumeMarkerMaxAttempts {
                timer.invalidate()
                // Timeout — fire anyway as a fallback
                NSLog(
                    "Session: resume marker not found"
                    + " after %d attempts, firing"
                    + " anyway",
                    attempts
                )
                action()
            }
        }
    }

    /// How many rows above the input box to scan for the
    /// resume marker. The marker appears in the last few
    /// lines of output, just above the prompt.
    private static let resumeMarkerScanRows = 10

    /// Scan the scrollback buffer backwards for the resume
    /// marker. Uses getScrollInvariantLine — the same API
    /// as isGenuineInterrupt in SessionManager — which
    /// produces clean strings without null-byte artifacts.
    private func bufferContainsResumeMarker() -> Bool {
        guard let tv = terminalView,
              let terminal = tv.terminal
        else { return false }

        let buf = terminal.buffer
        let top = buf.linesTop
        let end = top + buf.lines.count
        let scanStart = max(
            top, end - Self.resumeMarkerScanRows
        )

        for row in stride(
            from: end - 1, through: scanStart, by: -1
        ) {
            guard let line = terminal
                .getScrollInvariantLine(row: row)
            else { continue }
            let text = line.translateToString(
                trimRight: true
            )
            if text.contains(Self.resumeMarker) {
                return true
            }
        }
        return false
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
            // A dead process is never busy — clear state and timer
            self.busyDebounceTimer?.invalidate()
            self.busyDebounceTimer = nil
            if self.isBusy {
                self.isBusy = false
            }

            // Clear turn state
            if self.isInTurn {
                self.isInTurn = false
                self.turnStartTime = nil
            }

            // Clear any pending idle actions — session is dead
            self.afterNextIdleActions.removeAll()
            self.afterNextIdleArmed = false

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
