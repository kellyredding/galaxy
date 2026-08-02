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
/// concrete engine (SwiftTerm is the only one today) is
/// selected by `TerminalBackendFactory` from the
/// global `AppSettings.terminalEngine` setting at
/// construction time and pinned for the pane's lifetime
/// (D-pane). No `Session` coupling beyond a weak reference
/// used for routing bell events into the session-bell
/// pipeline and targeting the session's terminal for
/// "Send to Claude" pastes.
final class ShellTerminalPane: BackendBackedPane, ObservableObject {
    let backend: TerminalBackend

    /// Where configuration comes from, and how a change to it arrives.
    var settings: GalacticConfigurationSource { SettingsManager.shared }

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
    @Published var isRunning: Bool = false

    var paneKind: TerminalPaneKind { .shell }
    var ledgerSessionId: Int64? { session?.ledgerSessionId }

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
        observeSettings(storingIn: &cancellables)
    }

    /// Launch the user's login shell in the resolved cwd.
    func start() {
        startShell(
            ShellLaunch(
                executable: ShellEnvironment.userLoginShell(),
                workingDirectory: ShellLauncher.resolveCwd(for: session),
                environment: ShellLauncher.buildEnvironment(),
                // A user sitting at a prompt: the profile a login shell reads,
                // and the behaviour an interactive one has.
                arguments: ["-il"]
            )
        )
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

    // MARK: - Private

    private func wireBackend() {
        forwardProcessExit()
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
}
