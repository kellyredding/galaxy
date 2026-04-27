import AppKit
import Combine
import SwiftTerm

/// Contract for any terminal surface hostable by
/// `TerminalHostView`. Abstracts the Session pane (Claude) vs
/// Shell pane differences into a uniform interface for
/// scrollback, drag-drop, focus, and exit handling.
///
/// Conformers (introduced across later phases):
/// - `SessionTerminalPane` — wraps `GalaxyTerminalView` + `Session`
/// - `ShellTerminalPane` — wraps `LocalProcessTerminalView` via
///   a `TerminalBackend`, no Claude coupling
///
/// This is the libghostty swap seam at the chrome boundary.
/// Backends (PTY + rendering library) swap via
/// `TerminalBackend`; chrome hosts (drag-drop, scrollback,
/// focus, keyboard) swap via this protocol.
protocol TerminalPane: AnyObject {
    /// The inner NSView that renders the terminal.
    var view: NSView { get }

    /// Snapshot the current buffer for scrollback rendering.
    /// Returns nil if not available (pane teardown in
    /// progress, no active buffer, etc.).
    func snapshotBuffer() -> Buffer?

    /// Send typed text. Used by drag-drop (bracketed paste)
    /// and "Send to Claude" routing.
    func send(text: String)

    /// Make the inner terminal the first responder.
    func focus()

    /// Whether this pane should accept dropped files right
    /// now. Gates drag-drop registration in
    /// `TerminalHostView.updateDragRegistration`.
    var isAcceptingInput: Bool { get }

    /// Called when the underlying process terminates with
    /// an exit code. Owning container (e.g.
    /// `TerminalTabSplitView`) uses this to tear down.
    var onProcessExit: ((Int32) -> Void)? { get set }

    /// Called when the terminal rings the bell. Owning
    /// container routes into the session-bell pipeline.
    var onBell: (() -> Void)? { get set }

    /// Identifier for the `pane` field in timeline events.
    /// Valid values: `"session"` or `"shell"`.
    var paneKind: String { get }

    /// Ledger session ID for timeline event attribution.
    /// Nil if the pane has no ledger context (shell pane
    /// whose owning Claude session hasn't been enriched
    /// yet, for example).
    var ledgerSessionId: Int64? { get }

    /// Target terminal that receives "Send to Claude" pastes
    /// from this pane's scrollback. Typically:
    /// - Session pane → self (pastes land in own terminal)
    /// - Shell pane → the owning session's terminal view
    ///
    /// Returns nil when sending is fundamentally impossible
    /// (no session at all). Non-nil with a set
    /// `disabledReason` means the UI should show the button
    /// disabled with the given tooltip.
    var sendToClaudeTarget: SendToClaudeTarget? { get }

    /// Callback invoked when the user scrolls the terminal
    /// upward. Return `true` to consume the event (e.g.,
    /// entered scrollback), `false` to let normal scrolling
    /// proceed. Set by `TerminalHostView` to route scroll-up
    /// into the scrollback-creation path uniformly for both
    /// panes.
    var onScrollUp: ((NSEvent) -> Bool)? { get set }

    /// Callback invoked after any user-initiated scroll
    /// motion that moved the viewport downward (wheel,
    /// page-down, scroller knob drag). Set by
    /// `TerminalHostView` to invoke
    /// `snapViewportToBottomIfWithin` and lock auto-follow
    /// when the user has scrolled to or near the bottom.
    /// Direction is detected at the source so a 1-row
    /// scroll-up doesn't bounce back to bottom.
    var onScrollDown: (() -> Void)? { get set }

    /// If the viewport is within `rows` lines of the
    /// buffer bottom but not exactly at it, snap to the
    /// bottom and clear the underlying terminal's
    /// auto-follow gate so subsequent output streams
    /// pin to the latest line. Returns true if the snap
    /// fired, false otherwise (already at bottom, far
    /// from bottom, or selection active). Pane impls
    /// forward to whichever subsystem owns the snap
    /// (the backend for Shell, the SwiftTerm subclass
    /// directly for Session).
    func snapViewportToBottomIfWithin(rows: Int) -> Bool

    /// Current font size for this pane's terminal. Per-pane
    /// so Session and Shell panes can diverge independently
    /// (⌘+/⌘- only affects the focused pane).
    var fontSize: CGFloat { get }

    /// Publisher that emits whenever `fontSize` changes.
    /// Used by `TerminalHostView` to re-render the scrollback
    /// overlay with updated font metrics, without caring
    /// whether the source is a session or a shell pane.
    var fontSizePublisher: AnyPublisher<CGFloat, Never> { get }
}

/// Describes where a "Send to Claude" action should route
/// its formatted message, and the preflight check that
/// gates the send.
///
/// Both panes produce one of these; the scrollback overlay
/// consults `disabledReason()` to decide whether the
/// button is enabled, and calls `sendText` + `sendCR` when
/// the user clicks Send.
struct SendToClaudeTarget {
    /// Inject text into the target terminal
    /// (bracketed paste).
    let sendText: (String) -> Void

    /// Send a single CR to submit. Called ~300ms after
    /// `sendText` so the TUI has time to register the
    /// paste as input before Enter arrives.
    let sendCR: () -> Void

    /// Preflight: nil = enabled, Some(reason) = disabled
    /// with the given tooltip string.
    let disabledReason: () -> String?
}
