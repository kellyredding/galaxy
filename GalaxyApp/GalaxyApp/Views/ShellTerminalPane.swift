import AppKit
import Combine
import SwiftTerm

/// Pair wrapper over (style, blink) so Combine can dedupe
/// changes as a single unit. Without this, two independent
/// subscriptions on `shellCursorStyle` and `shellCursorBlink`
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
/// Owns a `SwiftTermBackend` for the PTY + rendering. No
/// `Session` coupling beyond a weak reference used for
/// routing bell events into the session-bell pipeline and
/// targeting the session's terminal for "Send to Claude"
/// pastes.
final class ShellTerminalPane: TerminalPane, ObservableObject {
    private let backend: SwiftTermBackend

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

    var onScrollUp: ((NSEvent) -> Bool)? {
        get { backend.onScrollUp }
        set { backend.onScrollUp = newValue }
    }

    var fontSizePublisher: AnyPublisher<CGFloat, Never> {
        $fontSize.eraseToAnyPublisher()
    }

    private var cancellables = Set<AnyCancellable>()

    init(session: Session) {
        self.session = session
        self.backend = SwiftTermBackend(
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

    /// Send SIGTERM via the backend. SwiftTermBackend's current
    /// implementation maps this to a full `terminate()` (signal
    /// arg is ignored — see its TODO). Shell process exit fires
    /// `onProcessTerminated` which clears `isRunning`, prompting
    /// teardown.
    func requestClose() {
        guard isRunning else { return }
        backend.terminateProcess(signal: SIGTERM)
        // Escalate to SIGKILL if the shell doesn't exit within
        // 250ms. Today this is also mapped to plain terminate()
        // by SwiftTermBackend, so it's redundant — but once
        // signal-level control lands (Phase 2.5 or later), this
        // will be the real kill path.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.25
        ) { [weak self] in
            guard let self = self, self.isRunning else {
                return
            }
            self.backend.terminateProcess(signal: SIGKILL)
        }
    }

    func snapshotBuffer() -> Buffer? {
        backend.snapshotBuffer()
    }

    func send(text: String) {
        backend.send(text: text)
    }

    func focus() {
        backend.focus()
    }

    /// Shell pane's Send-to-Claude routes pastes to the owning
    /// Claude session's terminal. Phase 2 scope: only the
    /// session-stopped blocker — session-scrollback-open
    /// detection is deferred to Phase 3 (live state updates).
    var sendToClaudeTarget: SendToClaudeTarget? {
        guard let s = session else { return nil }
        let sessionView = s.terminalView

        return SendToClaudeTarget(
            sendText: { [weak sessionView] text in
                sessionView?.send(txt: text)
            },
            sendCR: { [weak sessionView] in
                sessionView?.send([0x0D])
            },
            disabledReason: { [weak s] in
                guard let s = s else {
                    return "Session unavailable"
                }
                if !s.isRunning || s.hasExited {
                    return "Resume the session first"
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
        applyFont()
    }

    func decreaseFontSize() {
        let step = AppSettings.terminalFontSizeStep
        let range = AppSettings.terminalFontSizeRange
        fontSize = max(fontSize - step, range.lowerBound)
        applyFont()
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
        // No onDataReceived subscription — shell pane doesn't
        // track busy state.
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
    /// Slightly longer than `bellFlashDuration` so the
    /// gate clears after the overlay is fully torn down
    /// — never shorter, or rapid bells would stack
    /// overlays.
    private static let bellDebounceWindow: TimeInterval = 0.24

    /// Total duration of the bell pulse (rise + fall).
    /// Long enough to feel like a deliberate pulse
    /// rather than a snap, short enough to stay crisp.
    private static let bellFlashDuration: TimeInterval = 0.20

    /// Peak opacity of the pulse. Dimmer than the old
    /// snap-in overlay because a pulse gives the eye
    /// more time to register the flash, so it doesn't
    /// need to shout.
    private static let bellFlashPeakOpacity: Float = 0.25

    /// Fraction of the total duration at which the pulse
    /// reaches peak. A quick rise (25%) then a longer
    /// decay (75%) feels more like a pulse than a
    /// symmetric triangle.
    private static let bellFlashPeakFraction: Double = 0.25

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

    /// Pulse a neutral-gray overlay across the terminal:
    /// rise quickly to peak, then decay back to zero.
    /// Neutral 0.5 gray is theme-agnostic (sits between
    /// light and dark backgrounds without fighting
    /// either). Sibling-view approach (vs. swapping
    /// terminal colors) avoids racing SwiftTerm's render
    /// cadence, and `.above` positioning pins the
    /// overlay on top of the caret so the cursor can't
    /// peek through during the pulse.
    ///
    /// Uses `CAKeyframeAnimation` rather than chained
    /// `NSAnimationContext` groups: one Core Animation
    /// call gives smoother interpolation and avoids the
    /// inter-group jitter you get when chaining two
    /// separate animation runs.
    private func flashVisualBell() {
        let target = backend.view
        let flash = NSView(frame: target.bounds)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.gray.cgColor
        flash.autoresizingMask = [.width, .height]
        // Base layer opacity is 0 — the animation
        // overlays the temporary pulse curve, and when
        // the animation ends the layer snaps back to 0
        // (invisible) before `removeFromSuperview`
        // fires, so there's no end-of-pulse flicker.
        flash.layer?.opacity = 0
        target.addSubview(
            flash, positioned: .above, relativeTo: nil
        )

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [
            0,
            Self.bellFlashPeakOpacity,
            0
        ]
        pulse.keyTimes = [
            0,
            NSNumber(value: Self.bellFlashPeakFraction),
            1
        ]
        pulse.duration = Self.bellFlashDuration
        // Ease-out on the rise so the pulse pops in
        // crisply; ease-in on the fall so the tail
        // feels gentle rather than cliff-edged.
        pulse.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn)
        ]
        flash.layer?.add(pulse, forKey: "pulse")

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.bellFlashDuration
        ) {
            flash.removeFromSuperview()
        }
    }

    private func subscribeToSettings() {
        let mgr = SettingsManager.shared

        // Font family (global — applies to both panes).
        mgr.$settings
            .map(\.terminalFontFamily)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyFont() }
            .store(in: &cancellables)

        // Color theme (global).
        mgr.$settings
            .map(\.terminalColorThemeName)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyColors() }
            .store(in: &cancellables)

        // Scrollback size (global).
        mgr.$settings
            .map(\.terminalScrollbackLines)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lines in
                self?.backend.changeHistorySize(lines)
            }
            .store(in: &cancellables)

        // Cursor (shell-only). SwiftTerm's `CursorStyle`
        // fuses shape + blink, so dedupe on the pair to
        // avoid redundant applies — two separate
        // subscriptions would fire twice on init. Routed
        // through the backend's `applyCursor` to keep the
        // mapping in one place.
        mgr.$settings
            .map {
                ShellCursorConfig(
                    style: $0.shellCursorStyle,
                    blink: $0.shellCursorBlink
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
        applyColors()
        applyFont()
        backend.changeHistorySize(
            SettingsManager.shared.settings.terminalScrollbackLines
        )
        let s = SettingsManager.shared.settings
        backend.applyCursor(
            style: s.shellCursorStyle,
            blink: s.shellCursorBlink
        )
    }

    private func applyFont() {
        let family =
            SettingsManager.shared.settings.terminalFontFamily
        let font: NSFont
        if family == "SF Mono" {
            font = NSFont.monospacedSystemFont(
                ofSize: fontSize, weight: .medium
            )
        } else {
            font = NSFont(name: family, size: fontSize)
                ?? NSFont.monospacedSystemFont(
                    ofSize: fontSize, weight: .regular
                )
        }
        backend.setFont(font)
    }

    private func applyColors() {
        let theme = TerminalColorTheme.theme(
            named: SettingsManager.shared
                .settings.terminalColorThemeName
        )
        backend.setForegroundColor(theme.foregroundColor)
        backend.setBackgroundColor(theme.backgroundColorValue)
        backend.installColors(theme.swiftTermPalette)
    }
}
