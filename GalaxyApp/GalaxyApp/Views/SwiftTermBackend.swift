import AppKit
import SwiftTerm

/// Internal `LocalProcessTerminalView` subclass that adds
/// a scroll-wheel interception hook and silences the
/// default bell. Kept file-private since the only reason
/// it exists is to let `SwiftTermBackend` satisfy
/// `TerminalBackend.onScrollUp` and to stop
/// SwiftTerm's default `bell(source:)` from firing an
/// NSBeep every time the shell rings (e.g., backspace at
/// line start).
final class ScrollInterceptingTerminalView: LocalProcessTerminalView {
    /// Called on scroll-wheel-up. Return `true` to consume
    /// the event, `false` to pass through to `super`.
    var onScrollUp: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if event.deltaY > 0,
           let callback = onScrollUp,
           callback(event) {
            return
        }
        super.scrollWheel(with: event)
    }

    /// Override to swallow the bell event entirely —
    /// skipping `super.bell(source:)` kills the NSBeep
    /// that SwiftTerm's default handler produces. Shell
    /// bell behavior (audible toggle + local visual
    /// flash) will be wired through shell-specific
    /// settings in a follow-up commit; today this is
    /// deliberately silent so routine shell events
    /// (backspace at line start, etc.) don't produce
    /// surprise beeps or sidebar flashes.
    override func bell(source: SwiftTerm.Terminal) {
        // intentionally empty — see doc comment above.
    }
}

/// `TerminalBackend` implementation using SwiftTerm's
/// `LocalProcessTerminalView` directly (no Galaxy
/// subclassing, no Claude-specific content monitor or turn
/// state).
///
/// Used by the Shell pane. The Session pane still touches
/// SwiftTerm through `GalaxyTerminalView` directly — its
/// migration to this backend is deferred until the
/// libghostty swap actually happens.
final class SwiftTermBackend: NSObject, TerminalBackend,
    LocalProcessTerminalViewDelegate {

    private let terminalView: ScrollInterceptingTerminalView

    var view: NSView { terminalView }
    var onProcessTerminated: ((Int32) -> Void)?
    var onBell: (() -> Void)?
    var onDataReceived: (() -> Void)?

    var onScrollUp: ((NSEvent) -> Bool)? {
        get { terminalView.onScrollUp }
        set { terminalView.onScrollUp = newValue }
    }

    init(frame: NSRect) {
        self.terminalView =
            ScrollInterceptingTerminalView(frame: frame)
        super.init()
        self.terminalView.processDelegate = self
        // Match GalaxyTerminalView's glyph-rendering
        // decision for CoreText parity with Terminal.app.
        self.terminalView.customBlockGlyphs = false
    }

    // MARK: - Process

    func startProcess(
        executable: String,
        args: [String],
        environment: [String],
        execName: String,
        currentDirectory: String
    ) {
        terminalView.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: execName,
            currentDirectory: currentDirectory
        )
    }

    /// Terminate the running subprocess.
    ///
    /// **Current caveat (Phase 2 TODO):** SwiftTerm's
    /// `LocalProcessTerminalView.terminate()` doesn't take
    /// a signal — it performs a full tear-down regardless.
    /// The `signal` argument is accepted for protocol
    /// conformance and forward-compatibility (libghostty
    /// may expose signal-level control), but ignored
    /// today. When the Shell pane lands in Phase 2 and
    /// needs SIGTERM→SIGKILL grace-period semantics, we'll
    /// extract `Session.captureChildPid` /
    /// `Session.terminateProcess` into a shared helper and
    /// use it here.
    func terminateProcess(signal: Int32) {
        NSLog(
            "SwiftTermBackend: terminateProcess signal=%d "
            + "(signal ignored; Phase 2 will add PID-level "
            + "control)",
            signal
        )
        terminalView.terminate()
    }

    // MARK: - IO

    func send(bytes: [UInt8]) {
        terminalView.send(bytes)
    }

    func send(text: String) {
        terminalView.send(txt: text)
    }

    // MARK: - Buffer / appearance

    func changeHistorySize(_ lines: Int) {
        terminalView.terminal.changeHistorySize(lines)
    }

    func installColors(_ palette: [SwiftTerm.Color]) {
        terminalView.installColors(palette)
    }

    func setForegroundColor(_ color: NSColor) {
        terminalView.nativeForegroundColor = color
    }

    func setBackgroundColor(_ color: NSColor) {
        terminalView.nativeBackgroundColor = color
    }

    func setFont(_ font: NSFont) {
        terminalView.font = font
    }

    func applyCursor(
        style: ShellCursorStyle, blink: Bool
    ) {
        // Collapse Galaxy's two orthogonal toggles into
        // SwiftTerm's 6-case `CursorStyle` enum. Setting
        // via `terminal.setCursorStyle` fires the delegate
        // hook which updates `MacCaretView`'s shape and
        // toggles the blink animation off the CALayer
        // opacity keypath.
        let mapped: SwiftTerm.CursorStyle = {
            switch (style, blink) {
            case (.block, true):        return .blinkBlock
            case (.block, false):       return .steadyBlock
            case (.underline, true):    return .blinkUnderline
            case (.underline, false):   return .steadyUnderline
            case (.verticalBar, true):  return .blinkBar
            case (.verticalBar, false): return .steadyBar
            }
        }()
        terminalView.terminal.setCursorStyle(mapped)
    }

    func snapshotBuffer() -> Buffer? {
        terminalView.terminal.snapshotBuffer(
            terminalView.terminal.buffer
        )
    }

    // MARK: - Focus

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func processTerminated(
        source: TerminalView,
        exitCode: Int32?
    ) {
        onProcessTerminated?(exitCode ?? 0)
    }

    func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {
        // No-op — SwiftTerm reflows internally.
    }

    func setTerminalTitle(
        source: LocalProcessTerminalView,
        title: String
    ) {
        // No-op — Shell pane doesn't display a title.
    }

    func hostCurrentDirectoryUpdate(
        source: TerminalView,
        directory: String?
    ) {
        // No-op — Shell pane doesn't track cwd.
    }
}
