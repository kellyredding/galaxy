import AppKit
import Combine
import Galactic

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
final class ShellTerminalPane: BackendBackedPane, ObservableObject {
    let backend: TerminalBackend

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

    var paneKind: TerminalPaneKind { .shell }
    var ledgerSessionId: Int64? { session?.ledgerSessionId }
    var acceptsFileDrops: Bool { isRunning }

    var onProcessExit: ((Int32) -> Void)?

    /// Storage rather than a forward to the backend, because this pane claims
    /// the engine's callback for its own bell policy and re-emits through this
    /// one afterwards. The sibling session pane forwards instead, since its
    /// policy lives in `SessionManager`.
    ///
    /// That asymmetry is a symptom of the policy being written twice, and it
    /// resolves when the debounce becomes one shared mechanism — at which point
    /// both panes forward and neither owns a pipeline.
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

    /// Shell pane's Send-to-Claude routes pastes to the owning
    /// Claude session's terminal. Disabled with a tooltip when
    /// the session isn't running (takes precedence) or the
    /// session pane's scrollback overlay is open — sending
    /// into a paused buffer view would land out-of-order.
    var sendToClaudeTarget: SendToClaudeTarget? {
        guard let s = session else { return nil }

        return SendToClaudeTarget(
            // Routed through the session rather than straight at its backend, so
            // this pane inherits the readiness wait and the pacing instead of
            // reimplementing them a second time.
            send: { [weak s] text in
                s?.sendCommand(text, verifyAccepted: false)
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
                if s.paneRegistry.sessionPaneScrollbackActive {
                    return "Close session scrollback first"
                }
                return nil
            }
        )
    }

    /// Where View ▸ Default returns to. The pane's own size is per-instance
    /// and in memory; this is the configured one every pane starts from.
    var defaultFontSize: CGFloat {
        SettingsManager.shared.settings.defaultTerminalFontSize
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

    /// Collapses a rapid BEL burst (holding backspace at line start is enough)
    /// into one flash rather than a flicker.
    ///
    /// The same mechanism the session pipeline uses, with a much shorter window
    /// because this pane's response is shorter: a sound and one overlay
    /// animation, not a three-flash cadence and a notification. Slightly longer
    /// than the overlay's own duration so the gate clears after teardown —
    /// never shorter, or bells would stack overlays.
    private let bellDebounce = TerminalBellDebounce(window: 0.24)

    /// Apply shell-bell side effects per current settings.
    /// Called from `backend.onBell` (pane-local, no
    /// SessionManager involvement) so shell bells never
    /// trigger sidebar red-dot flashes or macOS
    /// notifications — those are reserved for
    /// Claude-attention events.
    private func handleBell() {
        // The gate hops to the main queue and holds the window itself.
        bellDebounce.fire { [weak self] in
            guard let self = self else { return }

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

        // Re-apply the full settings model on any change, handing it this
        // pane's own size — the configured default is where a pane starts, not
        // where it is now. `dropFirst()` skips the initial value, which
        // `applyInitialAppearance` pushes explicitly at start time.
        mgr.$settings
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                guard let self else { return }
                self.backend.applySettings(
                    settings, fontSize: self.fontSize
                )
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
                TerminalCursorConfig(
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
        backend.applySettings(settings, fontSize: fontSize)
        backend.applyCursor(
            style: settings.terminalCursorStyle,
            blink: settings.terminalCursorBlink
        )
    }

    /// Push this pane's own size to the backend, for the zoom gestures.
    ///
    /// Only the font — a zoom has no business rebuilding the colour table or
    /// reallocating scrollback, which is why this is not a settings re-apply.
    func applyFontSize() {
        let family =
            SettingsManager.shared.settings.terminalFontFamily
        backend.setFont(
            resolveTerminalFont(family: family, size: fontSize)
        )
    }
}
