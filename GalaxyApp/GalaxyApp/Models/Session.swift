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

    /// The resolved name to sync to Claude Code via /rename.
    /// Same cascade as displayName but without the "(sessionRef)" suffix.
    var claudeSessionName: String {
        if let name = givenName, !name.isEmpty {
            return name
        }
        if givenName == nil, let suggested = ledgerSuggestedName, !suggested.isEmpty {
            return suggested
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

    // MARK: - View State (per-session, not persisted)
    // Tracks which tab/subtab this session was on when the user switched
    // away. Restored by SessionManager when switching back.

    /// Last active main tab for this session. Defaults to terminal.
    var lastActiveTab: SessionTab = .terminal

    /// Last active ledger subtab for this session. Defaults to last activity.
    var lastActiveLedgerSubTab: LedgerSubTab = .lastActivity

    /// Tracks the last name sent via /rename to avoid duplicate commands.
    /// Transient — not persisted. Cleared in processDidExit so resume
    /// re-sends the name.
    private(set) var lastRenamedTo: String?

    /// Set when syncSessionName() is called while the session is busy.
    /// Checked on the next busy→idle transition to retry the rename.
    private var needsNameSync: Bool = false

    /// Sustained-idle timer for name sync. Scheduled when the session
    /// goes idle with a pending rename; cancelled if the session goes
    /// busy before the interval elapses. Only fires (sending /rename)
    /// when the session remains continuously idle for the full interval.
    private var nameSyncTimer: Timer?

    // MARK: - Ledger Enrichment Data
    // Populated by EventCoordinator.applyEnrichmentData() on each
    // session.metrics event. Plain var (not @Published) until a
    // specific property is promoted for UI rendering.

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

    /// ISO timestamp of last user interaction
    var ledgerLastInteraction: String?

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

    /// How long the session must remain continuously idle before sending
    /// a /rename command. Prevents firing during brief gaps between tool
    /// calls in multi-step agentic turns. The total quiet period is
    /// busyDebounceInterval (0.5s) + this interval before /rename fires.
    private static let nameSyncSustainedIdleInterval: TimeInterval = 0.5

    /// When true, busy state changes are frozen (during drag/resize operations)
    private var isBusyPaused: Bool = false

    /// One-shot closures to fire on the next busy→idle transition.
    /// Armed when the session transitions idle→busy after being set.
    /// Fired and cleared on the subsequent busy→idle transition.
    private var afterNextIdleActions: [() -> Void] = []

    /// Whether the afterNextIdle actions have been armed (session went
    /// busy after they were registered). Prevents firing on a stale
    /// idle transition that was already in progress when actions were set.
    private var afterNextIdleArmed: Bool = false

    /// Persistent callback fired on every busy→idle transition.
    /// Set once by SessionManager for auto-clear context checks.
    var onIdleTransition: ((Session) -> Void)?

    /// Current terminal font size for this session (transient, not persisted)
    @Published var terminalFontSize: CGFloat {
        didSet {
            applyTerminalFontSize()
        }
    }

    let terminalView: GalaxyTerminalView
    let createdAt: Date
    let workingDirectory: String

    // Keep a strong reference to the process handler so it doesn't get deallocated
    var processHandler: TerminalProcessHandler?

    private var cancellables = Set<AnyCancellable>()

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
        // Disable custom block glyph rendering so block elements (U+2580-U+259F)
        // and box drawing (U+2500-U+257F) fall through to CoreText font rendering.
        // This lets the system font fallback produce glyphs that match Terminal.app.
        terminalView.customBlockGlyphs = false

        // Apply color theme from settings
        applyColorTheme()

        // Apply initial font
        applyTerminalFontSize()

        // Re-apply font when the font family setting changes
        SettingsManager.shared.$settings
            .map(\.terminalFontFamily)
            .removeDuplicates()
            .dropFirst()  // Skip initial value (already applied above)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyTerminalFontSize()
            }
            .store(in: &cancellables)

        // Observe color theme changes
        SettingsManager.shared.$settings
            .map(\.terminalColorThemeName)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyColorTheme()
            }
            .store(in: &cancellables)

        // Observe scrollback size changes
        SettingsManager.shared.$settings
            .map(\.terminalScrollbackLines)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyScrollbackSize()
            }
            .store(in: &cancellables)
    }

    /// Apply the selected color theme to the terminal view.
    private func applyColorTheme() {
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
        let lines = SettingsManager.shared.settings.terminalScrollbackLines
        terminalView.terminal.changeHistorySize(lines)
        NSLog("Session[%@]: Applied scrollback size %d lines", sessionRef, lines)
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

        // If already busy we can't use isBusy as a verification signal.
        // Fall back to the original fire-and-forget behavior.
        let wasBusy = isBusy

        // Send command text first
        terminalView.send(txt: command)

        // Small delay to ensure text is processed before CR
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandSubmitDelay) { [weak self] in
            guard let self = self, self.isRunning, !self.hasExited else { return }

            // Send CR (0x0D) - same byte as keyboard Return
            self.terminalView.send([0x0D])

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
            self.terminalView.send([0x0D])
            self.verifyCommandSubmit(retriesLeft: retriesLeft - 1)
        }
    }

    /// Request a /rename sync to Claude Code. If the session is idle,
    /// schedules a sustained-idle timer; if busy, defers to the next
    /// idle transition. The timer cancels if the session goes busy
    /// before it fires, ensuring /rename only sends during a genuine
    /// idle period — not during brief gaps between tool calls.
    func syncSessionName() {
        let resolved = claudeSessionName

        guard resolved != lastRenamedTo else {
            needsNameSync = false
            nameSyncTimer?.invalidate()
            nameSyncTimer = nil
            return
        }
        guard isRunning && !hasExited else { return }

        needsNameSync = true

        // Defer if session is busy — retry on next idle transition
        guard !isBusy else {
            NSLog("Session[%@]: Deferring name sync (busy) → \"%@\"",
                  sessionRef, resolved)
            return
        }

        // Schedule sustained-idle timer (replaces any pending one)
        nameSyncTimer?.invalidate()
        NSLog("Session[%@]: Scheduling name sync (%.1fs sustained idle) → \"%@\"",
              sessionRef, Self.nameSyncSustainedIdleInterval, resolved)
        nameSyncTimer = Timer.scheduledTimer(
            withTimeInterval: Self.nameSyncSustainedIdleInterval,
            repeats: false
        ) { [weak self] _ in
            self?.executeNameSync()
        }
    }

    /// Send the /rename command after the sustained-idle timer fires.
    /// Final guards re-check state in case conditions changed during
    /// the timer interval.
    private func executeNameSync() {
        nameSyncTimer = nil
        let resolved = claudeSessionName

        guard resolved != lastRenamedTo else {
            needsNameSync = false
            return
        }
        guard isRunning && !hasExited else { return }
        guard !isBusy else {
            // Went busy just as timer fired — defer to next idle
            NSLog("Session[%@]: Name sync timer fired but session is busy — deferring",
                  sessionRef)
            return
        }

        NSLog("Session[%@]: Syncing name → \"%@\"", sessionRef, resolved)
        needsNameSync = false
        lastRenamedTo = resolved
        sendCommand("/rename \(resolved)")
    }

    // MARK: - Busy State

    /// Called from onDataReceived callback (fires on SwiftTerm's dispatch queue).
    /// Dispatches to main thread for all state mutation.
    func markBusy() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning, !self.hasExited, !self.isBusyPaused else {
                return
            }

            // Only trigger @Published when actually changing (idle → busy)
            // This prevents unnecessary SessionRow re-renders during sustained output
            if !self.isBusy {
                self.isBusy = true
                NotificationService.shared.sessionDidBecomeBusy(self.id)

                // Cancel pending sustained-idle name sync — session went busy
                self.nameSyncTimer?.invalidate()
                self.nameSyncTimer = nil

                // Arm pending one-shot actions on idle→busy transition
                if !self.afterNextIdleActions.isEmpty {
                    self.afterNextIdleArmed = true
                }
            }

            // Always reset the debounce timer (even when already busy)
            self.busyDebounceTimer?.invalidate()
            self.busyDebounceTimer = Timer.scheduledTimer(
                withTimeInterval: Self.busyDebounceInterval,
                repeats: false
            ) { [weak self] _ in
                guard let self = self else { return }
                self.isBusy = false

                // Fire armed one-shot actions
                if self.afterNextIdleArmed && !self.afterNextIdleActions.isEmpty {
                    let actions = self.afterNextIdleActions
                    self.afterNextIdleActions.removeAll()
                    self.afterNextIdleArmed = false
                    for action in actions {
                        action()
                    }
                } else if !self.afterNextIdleActions.isEmpty {
                    // Actions pending but not armed — skip (no busy→idle cycle yet)
                }

                // Retry deferred name sync
                if self.needsNameSync {
                    self.syncSessionName()
                }

                // Fire persistent idle callback
                self.onIdleTransition?(self)
            }
        }
    }

    /// Freeze busy state during drag/resize operations to prevent animation jank
    func pauseBusyObserver() {
        isBusyPaused = true
        busyDebounceTimer?.invalidate()
        busyDebounceTimer = nil
    }

    /// Resume busy state observation after drag/resize completes.
    /// If still busy, restarts debounce timer so it can naturally transition to idle.
    func resumeBusyObserver() {
        isBusyPaused = false

        // If we were busy when paused, restart the debounce timer
        // so it transitions to idle if no more output arrives
        if isBusy {
            busyDebounceTimer?.invalidate()
            busyDebounceTimer = Timer.scheduledTimer(
                withTimeInterval: Self.busyDebounceInterval,
                repeats: false
            ) { [weak self] _ in
                self?.isBusy = false
            }
        }
    }

    /// Register a one-shot action to fire after the next complete
    /// busy→idle cycle. Multiple actions can be queued; all fire
    /// together. The armed pattern ensures we wait for the session
    /// to go busy first, preventing premature fires if the session
    /// is already idle when this is called.
    func afterNextIdle(_ action: @escaping () -> Void) {
        afterNextIdleActions.append(action)
        afterNextIdleArmed = false
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
    /// state with a fresh terminal view and no running process.
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
        self.terminalView = GalaxyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )

        // Restore Galaxy-only state
        self.givenName = state.givenName

        // Stopped state — no running process
        self.isRunning = false
        self.hasExited = true

        applyScrollbackSize()

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

        configureTerminal()
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
            self.lastRenamedTo = nil
            self.needsNameSync = false
            self.nameSyncTimer?.invalidate()
            self.nameSyncTimer = nil

            // A dead process is never busy — clear state and timer
            self.busyDebounceTimer?.invalidate()
            self.busyDebounceTimer = nil
            if self.isBusy {
                self.isBusy = false
            }

            // Clear any pending idle actions — session is dead
            // Discard any pending idle actions — session is dead
            self.afterNextIdleActions.removeAll()
            self.afterNextIdleArmed = false
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
