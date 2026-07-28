import AppKit
import Combine
import Galactic

/// Contract for any terminal surface hostable by
/// `TerminalHostView`. Abstracts the Session pane (Claude) vs
/// Shell pane differences into a uniform interface for
/// scrollback, drag-drop, focus, and exit handling.
///
/// Conformers:
/// - `SessionTerminalPane` — wraps a `TerminalBackend` + `Session`
/// - `ShellTerminalPane` — wraps a `TerminalBackend` directly,
///   no Claude coupling
///
/// This is the libghostty swap seam at the chrome boundary.
/// Backends (PTY + rendering library) swap via
/// `TerminalBackend`; chrome hosts (drag-drop, scrollback,
/// focus, keyboard) swap via this protocol.
protocol TerminalPane: AnyObject {
    /// The inner NSView that renders the terminal.
    var view: NSView { get }

    /// Capture the current scrollback buffer for the overlay.
    /// Returns an opaque `ScrollbackSnapshot` that the chrome
    /// can render immediately and again on theme/font changes
    /// to reflow the same captured state. Returns nil if not
    /// available (pane teardown in progress, no active
    /// buffer, etc.).
    func captureScrollbackSnapshot() -> ScrollbackSnapshot?

    /// Send typed text. When `asPaste` is true and the terminal
    /// has bracketed-paste-mode enabled, the pane wraps the text
    /// in bracketed-paste sequences so the remote process can
    /// distinguish a paste from typed input. When bracketed-paste-
    /// mode is disabled or `asPaste` is false, the text is sent
    /// verbatim. Used by drag-drop (bracketed paste) and keystroke
    /// injection (plain).
    func send(text: String, asPaste: Bool)

    /// Make the inner terminal the first responder.
    func focus()

    /// Whether this pane should accept dropped files right now.
    /// Gates drag-drop registration in
    /// `TerminalHostView.updateDragRegistration`.
    ///
    /// Names file drops specifically because it has nothing to do with
    /// whether the child can read typed input — that is
    /// `whenAcceptingInput`, and conflating the two is how a keystroke
    /// gets written into a terminal that cannot yet receive it.
    var acceptsFileDrops: Bool { get }

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

    /// True when the underlying terminal has scrollback
    /// content above the viewport. Both panes forward to
    /// their respective surfaces; chrome consumes via
    /// `pane.hasScrollbackContent` to gate overlay creation.
    var hasScrollbackContent: Bool { get }

    /// Current viewport top row inside the scrollback
    /// buffer. Both panes forward to their respective
    /// surfaces; chrome uses this as the initial scroll
    /// position when creating the scrollback overlay.
    var viewportRow: Int { get }

    /// Clear any active text selection on the underlying
    /// terminal. Called before opening the scrollback
    /// overlay.
    func clearSelection()

    /// Active font on the underlying terminal surface.
    /// The scrollback HTML renderer reads `fontName` and
    /// `pointSize` for CSS matching against the live cells.
    var font: NSFont { get }

    /// Pixel height of one terminal cell. Used for CSS
    /// line-height in the scrollback overlay so frozen
    /// cells align with their live counterparts during the
    /// open animation.
    var cellHeight: CGFloat { get }

    /// Force a paint of the underlying terminal surface.
    /// Used to recover from stalled-render cases (e.g.
    /// window going inactive) where the chrome can see the
    /// stale state but can't trigger a redraw via AppKit
    /// alone.
    func redraw()

    /// Unconditionally snap the viewport to the bottom of
    /// the scrollback buffer and clear the `userScrolling`
    /// gate so subsequent output auto-follows. No threshold,
    /// no selection-active guard, no return value. Used by
    /// the scrollback overlay's `onReady` hook.
    func snapViewportToBottom()

    /// Current font size for this pane's terminal. Per-pane
    /// so Session and Shell panes can diverge independently
    /// (⌘+/⌘- only affects the focused pane).
    var fontSize: CGFloat { get }

    /// Publisher that emits whenever `fontSize` changes.
    /// Used by `TerminalHostView` to re-render the scrollback
    /// overlay with updated font metrics, without caring
    /// whether the source is a session or a shell pane.
    var fontSizePublisher: AnyPublisher<CGFloat, Never> { get }

    /// Bump this pane's terminal font size by one step, up to
    /// the global terminal font-size ceiling. The View ▸
    /// Bigger menu action routes here so the chrome layer
    /// never reaches into a backend-specific zoom path.
    func increaseFontSize()

    /// Drop this pane's terminal font size by one step, down
    /// to the global terminal font-size floor.
    func decreaseFontSize()

    /// Reset this pane's terminal font size to the default
    /// from `AppSettings.defaultTerminalFontSize`.
    func resetFontSize()

    /// Whether the pane's font size is below the ceiling and
    /// can take another increase step. Drives the View ▸
    /// Bigger menu item's enabled state.
    var canIncreaseFontSize: Bool { get }

    /// Whether the pane's font size is above the floor and
    /// can take another decrease step. Drives the View ▸
    /// Smaller menu item's enabled state.
    var canDecreaseFontSize: Bool { get }

    /// Trim the terminal's scrollback and reflow the viewport (the
    /// "Trim Buffer" gesture). Forwards to
    /// `TerminalBackend.trimBuffer()`.
    func trimBuffer()

    /// Reflow the terminal's viewport without trimming scrollback (the
    /// "Reflow Buffer" gesture). Forwards to
    /// `TerminalBackend.reflowBuffer()`.
    func reflowBuffer()

    /// Re-assert live-bottom follow when the user intends to be following
    /// (no-op in scrollback or when parked). Fired on focus-class events as a
    /// friendly re-pin. Forwards to `TerminalBackend.reassertFollowIfIntended()`.
    func reassertFollowIfIntended()
}

/// Describes where a "Send to Claude" action should route
/// its formatted message, and the preflight check that
/// gates the send.
///
/// Both panes produce one of these; the scrollback overlay
/// consults `disabledReason()` to decide whether the button is
/// enabled, and calls `send` when the user clicks Send.
struct SendToClaudeTarget {
    /// Hand composed text to the owning session, which types it
    /// and commits it.
    ///
    /// One closure rather than a write and a submit the caller
    /// paces itself. `Session.sendCommand` already owns that
    /// sequence — wait for the child to be able to read, type,
    /// pace, then submit whichever bytes the pane will act on —
    /// and a second implementation of it drifted: it paced with a
    /// number of its own for three months, and never gained the
    /// readiness wait at all. Nothing here resolves the submit
    /// bytes either, deliberately, because which ones work
    /// depends on what Return currently means in that pane.
    let send: (String) -> Void

    /// Preflight: nil = enabled, Some(reason) = disabled
    /// with the given tooltip string.
    let disabledReason: () -> String?
}
