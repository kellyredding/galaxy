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

    /// Called on scroll-wheel-up. Return `true` to consume
    /// the event (e.g., entered scrollback), `false` to
    /// let normal scrolling proceed.
    var onScrollUp: ((NSEvent) -> Bool)? { get set }

    /// Called after any user-initiated scroll lands at a
    /// new viewport position (wheel, page-down, scroller
    /// drag — anything routed through `scrollTo`). Fires
    /// only when the resulting `yDisp` actually moved
    /// downward, so a scroll-up landing one row above
    /// bottom doesn't trigger a near-bottom snap. Used
    /// by `TerminalHostView` to invoke
    /// `snapViewportToBottomIfWithin` and lock auto-follow.
    var onScrollDown: (() -> Void)? { get set }

    /// If the viewport is within `rows` lines of the
    /// buffer bottom but not exactly at it, snap to the
    /// bottom and clear `userScrolling` so subsequent
    /// output auto-follows. Returns true if the snap
    /// fired, false otherwise (already at bottom, far
    /// from bottom, or selection active). Selection-
    /// active calls are no-ops to preserve the
    /// `selectionChanged` viewport-freeze contract.
    func snapViewportToBottomIfWithin(rows: Int) -> Bool

    /// True when the scrollback buffer has any content
    /// above the current viewport (i.e. `yBase > 0`).
    /// Used by chrome to gate scrollback overlay creation
    /// — there's no point opening the overlay if there's
    /// nothing above to look at.
    var hasScrollbackContent: Bool { get }

    /// Current viewport top row inside the scrollback
    /// buffer (`yDisp`). Used as the initial scroll
    /// position when opening the scrollback overlay so
    /// the overlay opens at the user's current view
    /// rather than at the bottom.
    var viewportRow: Int { get }

    /// Clear any active text selection on the terminal
    /// surface. Called before opening the scrollback
    /// overlay so selection state doesn't bleed across
    /// the live → frozen transition.
    func clearSelection()
}
