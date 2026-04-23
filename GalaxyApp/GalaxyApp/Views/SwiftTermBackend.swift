import AppKit
import SwiftTerm

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

    private let terminalView: LocalProcessTerminalView

    var view: NSView { terminalView }
    var onProcessTerminated: ((Int32) -> Void)?
    var onBell: (() -> Void)?
    var onDataReceived: (() -> Void)?

    init(frame: NSRect) {
        self.terminalView =
            LocalProcessTerminalView(frame: frame)
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
