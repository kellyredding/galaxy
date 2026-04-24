import AppKit
import Combine
import SwiftTerm

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
            self?.onBell?()
        }
        // No onDataReceived subscription — shell pane doesn't
        // track busy state.
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
    }

    private func applyInitialAppearance() {
        applyColors()
        applyFont()
        backend.changeHistorySize(
            SettingsManager.shared.settings.terminalScrollbackLines
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
