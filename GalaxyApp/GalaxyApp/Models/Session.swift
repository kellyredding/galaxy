import Foundation
import AppKit
import Combine
import SwiftTerm

class Session: Identifiable, ObservableObject {
    /// Delay between sending command text and CR when invoking slash commands.
    /// Without this delay, the text and CR can get batched together, causing
    /// Ink (Claude Code's TUI framework) to not recognize the CR as a submit action.
    /// Tuned experimentally - shorter values may fail on loaded systems.
    private static let commandSubmitDelay: TimeInterval = 0.1  // 100ms

    /// UUID used for SwiftUI Identifiable AND as Claude's session ID
    let id: UUID

    /// Human-readable session reference for display (e.g., "rich-grass-hides")
    let sessionRef: String

    /// User-assigned name for this session. Galaxy-only — not shared with ledger.
    /// When set, displayName shows "givenName (sessionRef)".
    @Published var givenName: String?

    /// Display string for user-facing contexts (sidebar, menu, stopped screen).
    /// Shows given name with ref suffix when named, or bare ref when not.
    var displayName: String {
        if let name = givenName {
            return "\(name) (\(sessionRef))"
        }
        return sessionRef
    }

    @Published var isRunning: Bool = false
    @Published var hasExited: Bool = false
    @Published var exitCode: Int32?
    @Published var hasUnreadBell: Bool = false
    @Published var visualBellActive: Bool = false
    @Published var isBusy: Bool = false

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

    /// Send a slash command to the terminal (e.g., "/clear", "/compact")
    /// Only works when session is running
    func sendCommand(_ command: String) {
        guard isRunning && !hasExited else {
            NSLog("Session: Cannot send command - session not running")
            return
        }

        NSLog("Session: Sending command: %@", command)

        // Send command text first
        terminalView.send(txt: command)

        // Small delay to ensure text is processed before CR
        // Without delay, the CR arrives before text is fully processed
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandSubmitDelay) { [weak self] in
            guard let self = self else { return }
            // Send CR (0x0D) - same byte as keyboard Return
            self.terminalView.send([0x0D])
        }
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
        } else {
            cmd += " && CLAUDE_CLI_SESSION_ID=\(claudeSessionId) claude"
        }
        cmd += " --resume \(claudeSessionId)"
        if isVibe {
            cmd += " --vibe"
        }
        return cmd
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
