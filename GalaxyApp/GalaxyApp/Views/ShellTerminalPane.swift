import AppKit
import Combine
import Galactic

/// Pair wrapper over (style, blink) so Combine can dedupe
/// changes as a single unit. Without this, two independent
/// subscriptions on `terminalCursorStyle` and `terminalCursorBlink`
/// would each fire `applyCursor` on init — this struct lets
/// a single `.removeDuplicates()` guard the combined signal.
private struct ShellCursorConfig: Hashable {
    let style: ShellCursorStyle
    let blink: Bool
}

/// Non-Claude interactive shell pane. Runs the user's login
/// shell (`getpwuid_r` + `-il`), inherits user environment
/// minus Claude env vars (with forced `TERM=xterm-256color`),
/// and opens in the session's resolved cwd
/// (`ShellLauncher.resolveCwd`).
///
/// Owns a `TerminalBackend` for the PTY + rendering — the
/// concrete engine (SwiftTerm today; libghostty in the
/// future) is selected by `TerminalBackendFactory` from the
/// global `AppSettings.terminalEngine` setting at
/// construction time and pinned for the pane's lifetime
/// (D-pane). No `Session` coupling beyond a weak reference
/// used for routing bell events into the session-bell
/// pipeline and targeting the session's terminal for
/// "Send to Claude" pastes.
final class ShellTerminalPane: TerminalPane, ObservableObject {
    private let backend: TerminalBackend

    /// Weak ref to the owning Claude session. Used for bell
    /// routing and as the Send-to-Claude target.
    weak var session: Session?

    /// Per-shell-instance font size (in-memory, not persisted).
    /// Initialized from `session.terminalFontSize` on open so
    /// the split looks coherent on first show, then diverges
    /// with ⌘+/⌘-.
    @Published var fontSize: CGFloat

    /// True while the shell process is running. Flips to false
    /// on process exit, which `TerminalTabSplitView` observes
    /// to tear down the shell pane.
    @Published private(set) var isRunning: Bool = false

    var view: NSView { backend.view }
    var paneKind: String { "shell" }
    var ledgerSessionId: Int64? { session?.ledgerSessionId }
    var isAcceptingInput: Bool { isRunning }

    var onProcessExit: ((Int32) -> Void)?
    var onBell: (() -> Void)?

    /// Forwarded from the backend so external coordinators
    /// (`SessionManager.suppressFocusEventsAcrossPanes`) can
    /// quench mode-1004 focus escapes during cross-session
    /// switches without reaching past the Shell pane's
    /// encapsulation. Self-clears at the next responder
    /// transition; setting it has no effect outside that
    /// window.
    var suppressFocusEvents: Bool {
        get { backend.suppressFocusEvents }
        set { backend.suppressFocusEvents = newValue }
    }

    var onScrollUp: ((NSEvent) -> Bool)? {
        get { backend.onScrollUp }
        set { backend.onScrollUp = newValue }
    }

    var hasScrollbackContent: Bool { backend.hasScrollbackContent }
    var viewportRow: Int { backend.viewportRow }
    func clearSelection() { backend.clearSelection() }

    var font: NSFont { backend.font }
    var cellHeight: CGFloat { backend.cellHeight }
    func redraw() { backend.redraw() }
    func snapViewportToBottom() { backend.snapViewportToBottom() }

    var fontSizePublisher: AnyPublisher<CGFloat, Never> {
        $fontSize.eraseToAnyPublisher()
    }

    private var cancellables = Set<AnyCancellable>()

    init(session: Session) {
        self.session = session
        let engine = SettingsManager.shared.settings.terminalEngine
        self.backend = TerminalBackendFactory.make(
            engine: engine,
            kind: .shell,
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        self.fontSize = session.terminalFontSize
        wireBackend()
        subscribeToSettings()
    }

    /// Launch the user's login shell in the resolved cwd.
    func start() {
        let shell = ShellLauncher.userLoginShell()
        let cwd = ShellLauncher.resolveCwd(for: session)
        let env = ShellLauncher.buildEnvironment()

        applyInitialAppearance()

        backend.startProcess(
            executable: shell,
            args: ["-il"],
            environment: env,
            execName: (shell as NSString).lastPathComponent,
            currentDirectory: cwd
        )

        isRunning = true
        NSLog(
            "ShellTerminalPane: Started %@ in %@", shell, cwd
        )
    }

    /// Request that the shell exit. Sends SIGHUP via the
    /// backend; the backend escalates to SIGTERM after 0.5s
    /// and SIGKILL after 1s if the shell doesn't exit. SIGHUP
    /// is the canonical "terminal hangup" signal — most
    /// shells exit gracefully and save state (history, etc.)
    /// in response, while still having SIGTERM/SIGKILL as
    /// fallbacks for misbehaving plugins. Shell process exit
    /// fires `onProcessTerminated` which clears `isRunning`,
    /// prompting teardown.
    func requestClose() {
        guard isRunning else { return }
        backend.terminateProcess(signal: SIGHUP)
    }

    func captureScrollbackSnapshot() -> ScrollbackSnapshot? {
        backend.captureScrollbackSnapshot()
    }

    func send(text: String, asPaste: Bool) {
        backend.send(text: text, asPaste: asPaste)
    }

    func trimBuffer() { backend.trimBuffer() }

    func reflowBuffer() { backend.reflowBuffer() }

    func reassertFollowIfIntended() { backend.reassertFollowIfIntended() }

    func focus() {
        backend.focus()
    }

    /// Shell pane's Send-to-Claude routes pastes to the owning
    /// Claude session's terminal. Disabled with a tooltip when
    /// the session isn't running (takes precedence) or the
    /// session pane's scrollback overlay is open — sending
    /// into a paused buffer view would land out-of-order.
    var sendToClaudeTarget: SendToClaudeTarget? {
        guard let s = session else { return nil }
        let sessionBackend = s.backend

        return SendToClaudeTarget(
            sendText: { text in
                sessionBackend?.send(text: text, asPaste: false)
            },
            sendSubmit: {
                sessionBackend?.submitPrompt()
            },
            disabledReason: { [weak s] in
                guard let s = s else {
                    return "Session unavailable"
                }
                // Session-stopped takes precedence — it's the
                // more fundamental block.
                if !s.isRunning || s.hasExited {
                    return "Resume the session first"
                }
                if s.sessionPaneScrollbackActive {
                    return "Close session scrollback first"
                }
                return nil
            }
        )
    }

    // MARK: - Font size

    func increaseFontSize() {
        let step = AppSettings.terminalFontSizeStep
        let range = AppSettings.terminalFontSizeRange
        fontSize = min(fontSize + step, range.upperBound)
        applyPerPaneFontSize()
    }

    func decreaseFontSize() {
        let step = AppSettings.terminalFontSizeStep
        let range = AppSettings.terminalFontSizeRange
        fontSize = max(fontSize - step, range.lowerBound)
        applyPerPaneFontSize()
    }

    /// Reset to the global default terminal font size. Mirrors
    /// `Session.resetTerminalFontSize()` so the View ▸ Default
    /// menu action behaves identically across pane kinds.
    func resetFontSize() {
        fontSize = SettingsManager.shared.settings
            .defaultTerminalFontSize
        applyPerPaneFontSize()
    }

    var canIncreaseFontSize: Bool {
        fontSize < AppSettings.terminalFontSizeRange.upperBound
    }

    var canDecreaseFontSize: Bool {
        fontSize > AppSettings.terminalFontSizeRange.lowerBound
    }

    // MARK: - Private

    private func wireBackend() {
        backend.onProcessTerminated = { [weak self] exitCode in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRunning = false
                self.onProcessExit?(exitCode)
            }
        }
        backend.onBell = { [weak self] in
            self?.handleBell()
            // External observers (e.g. future telemetry)
            // still get the raw signal — the pane's own
            // handler above is the policy layer.
            self?.onBell?()
        }
    }

    /// True while a bell's side effects are in flight.
    /// Gates both audible and visual paths so a rapid
    /// BEL burst (e.g. holding backspace at line start)
    /// produces one flash, not a flicker. Matches the
    /// debounce philosophy of `SessionManager.handleBell`
    /// but scoped to this pane only.
    private var isHandlingBell = false

    /// Short debounce window covering the full bell
    /// pipeline (sound fire + flash overlay animation).
    /// Slightly longer than `TerminalVisualBell.duration`
    /// so the gate clears after the overlay is fully
    /// torn down — never shorter, or rapid bells would
    /// stack overlays.
    private static let bellDebounceWindow: TimeInterval = 0.24

    /// Apply shell-bell side effects per current settings.
    /// Called from `backend.onBell` (pane-local, no
    /// SessionManager involvement) so shell bells never
    /// trigger sidebar red-dot flashes or macOS
    /// notifications — those are reserved for
    /// Claude-attention events.
    private func handleBell() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard !self.isHandlingBell else { return }
            self.isHandlingBell = true
            DispatchQueue.main.asyncAfter(
                deadline: .now()
                    + Self.bellDebounceWindow
            ) { [weak self] in
                self?.isHandlingBell = false
            }

            let s = SettingsManager.shared.settings
            if s.shellBellAudible {
                SettingsManager.shared.playSound(
                    s.shellBellSound
                )
            }
            if s.shellBellVisualFlash {
                self.flashVisualBell()
            }
        }
    }

    /// Delegate to the shared `TerminalVisualBell` pulse
    /// so the Shell and Session panes render identical
    /// flashes. All pulse tuning (peak opacity,
    /// duration, curve) lives in one place; this method
    /// just picks the target view.
    private func flashVisualBell() {
        TerminalVisualBell.pulse(over: backend.view)
    }

    private func subscribeToSettings() {
        let mgr = SettingsManager.shared

        // Re-apply the full settings model on any change.
        // `backend.applySettings(_:)` covers theme, font
        // family, and scrollback; per-pane font size is the
        // one piece outside the AppSettings model and is
        // applied separately. `dropFirst()` skips the initial
        // value — `applyInitialAppearance` pushes it
        // explicitly at start time.
        mgr.$settings
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                self?.backend.applySettings(settings)
                self?.applyPerPaneFontSize()
            }
            .store(in: &cancellables)

        // Cursor. Kept separate from `applySettings` because
        // SwiftTerm's `CursorStyle` fuses shape + blink, so we
        // dedupe on the pair via `ShellCursorConfig` to avoid two
        // subscriptions firing on init. The same shared terminal
        // cursor settings drive the session pane too (applied in
        // Session.configureTerminal).
        mgr.$settings
            .map {
                ShellCursorConfig(
                    style: $0.terminalCursorStyle,
                    blink: $0.terminalCursorBlink
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                self?.backend.applyCursor(
                    style: config.style, blink: config.blink
                )
            }
            .store(in: &cancellables)
    }

    private func applyInitialAppearance() {
        let settings = SettingsManager.shared.settings
        backend.applySettings(settings)
        applyPerPaneFontSize()
        backend.applyCursor(
            style: settings.terminalCursorStyle,
            blink: settings.terminalCursorBlink
        )
    }

    /// Apply the per-pane font-size override (set via ⌘+/⌘−)
    /// to the backend. `backend.applySettings(_:)` uses the
    /// global default size; this overrides with the pane's
    /// per-instance value.
    private func applyPerPaneFontSize() {
        let family =
            SettingsManager.shared.settings.terminalFontFamily
        backend.setFont(
            resolveTerminalFont(family: family, size: fontSize)
        )
    }
}
