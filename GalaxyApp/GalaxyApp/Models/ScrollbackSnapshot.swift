import AppKit

/// Opaque snapshot of a terminal's scrollback at a point in
/// time. Backends produce concrete implementations from their
/// own internal buffer types; chrome holds the protocol type
/// and asks the snapshot to render itself when needed.
///
/// The snapshot IS the render-token. To re-render the same
/// captured state with a different theme or font (e.g. on a
/// settings change while the overlay is open), the chrome
/// calls `render(...)` with new arguments — the underlying
/// buffer state is unchanged.
///
/// This protocol is the chrome-facing seam; concrete impls
/// (e.g. `SwiftTermScrollbackSnapshot` in `SwiftTermBackend`)
/// own the SwiftTerm-typed fields and the renderer call. When
/// a future libghostty backend lands, it gets its own
/// `LibghosttyScrollbackSnapshot` with a `render(...)` impl
/// that uses Ghostty's buffer types — chrome doesn't change.
protocol ScrollbackSnapshot: AnyObject {
    /// Column count at snapshot time. Used by the overlay
    /// layout for line-width calculations.
    var cols: Int { get }

    /// Viewport top row at snapshot time. Used by chrome as
    /// the initial scroll position when opening the overlay
    /// so the overlay opens at the user's current view rather
    /// than at the bottom.
    var yDisp: Int { get }

    /// Render this snapshot to a complete HTML document with
    /// the given theme and font metrics. Idempotent —
    /// repeated calls produce the same HTML for the same
    /// args, so settings changes (theme, font family/size)
    /// can rebuild the overlay against the same frozen
    /// buffer state.
    func render(
        theme: TerminalColorTheme,
        fontFamily: String,
        fontSize: CGFloat,
        cellHeight: CGFloat
    ) -> String
}
