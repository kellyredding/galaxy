import AppKit
import SwiftTerm

/// Abstraction over the PTY + terminal rendering library.
/// Implementations wrap a concrete library (SwiftTerm via
/// `SwiftTermBackend` today; libghostty target in the
/// future). Callers address this protocol, not the library
/// directly.
///
/// The surface is intentionally minimal — just what the
/// Shell pane needs (later phases). Buffer inspection calls
/// beyond `snapshotBuffer()` (like `getLine`, mouse-mode
/// queries, etc.) are deliberately not on the protocol;
/// adding them would bloat the libghostty swap surface.
/// Extend only when a concrete use appears.
protocol TerminalBackend: AnyObject {
    /// The terminal surface as an NSView.
    var view: NSView { get }

    /// Launch a subprocess under the PTY.
    func startProcess(
        executable: String,
        args: [String],
        environment: [String],
        execName: String,
        currentDirectory: String
    )

    /// Terminate the running subprocess.
    ///
    /// - Parameter signal: POSIX signal number
    ///   (e.g., `SIGTERM`=15, `SIGKILL`=9).
    ///
    /// Implementations may fall back to a terse terminate
    /// if the underlying library doesn't expose signal-
    /// level control. See `SwiftTermBackend.terminateProcess`
    /// for the current caveat.
    func terminateProcess(signal: Int32)

    /// Send bytes to the PTY.
    func send(bytes: [UInt8])

    /// Send text to the PTY (UTF-8 encoded).
    func send(text: String)

    /// Adjust scrollback history size at runtime.
    func changeHistorySize(_ lines: Int)

    /// Install a 16-color ANSI palette.
    func installColors(_ palette: [SwiftTerm.Color])

    /// Set foreground / background colors.
    func setForegroundColor(_ color: NSColor)
    func setBackgroundColor(_ color: NSColor)

    /// Set the terminal font.
    func setFont(_ font: NSFont)

    /// Apply cursor appearance. SwiftTerm's native
    /// `CursorStyle` enum fuses shape + blink into one
    /// value, so we pass both here and let the backend
    /// map to the 6-case combination. Shell-only in
    /// practice today — the Session pane's caret is
    /// hidden by Claude Code's own cursor rendering, so
    /// it doesn't subscribe.
    func applyCursor(style: ShellCursorStyle, blink: Bool)

    /// Snapshot the current buffer for scrollback
    /// rendering. Returns nil if no buffer is available.
    func snapshotBuffer() -> Buffer?

    /// Make the terminal surface first responder.
    func focus()

    /// Called when the child process exits (success or
    /// otherwise). Exit code is SwiftTerm's best effort —
    /// nil becomes 0 for normalization.
    var onProcessTerminated: ((Int32) -> Void)? { get set }

    /// Called when the terminal parses a BEL byte.
    var onBell: (() -> Void)? { get set }

    /// Called on every byte slice the PTY delivers. Used
    /// by busy detection (session pane); shell pane doesn't
    /// subscribe.
    var onDataReceived: (() -> Void)? { get set }

    /// Called on scroll-wheel-up. Return `true` to consume
    /// the event (e.g., entered scrollback), `false` to
    /// let normal scrolling proceed.
    var onScrollUp: ((NSEvent) -> Bool)? { get set }
}
