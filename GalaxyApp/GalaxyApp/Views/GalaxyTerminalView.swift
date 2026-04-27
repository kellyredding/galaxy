import AppKit
import SwiftTerm

/// Custom terminal view that extends LocalProcessTerminalView.
/// This allows us to intercept terminal events (like bell) without
/// replacing the terminalDelegate, which breaks SwiftTerm's internal behavior.
class GalaxyTerminalView: LocalProcessTerminalView {
    /// Short-circuit key view traversal — same fix as InlineEditField.
    /// When any NSView becomes first responder, AppKit may walk
    /// previousValidKeyView / nextValidKeyView to validate the target.
    /// With the ZStack architecture keeping all session views alive,
    /// each traversal walks thousands of SwiftUI-managed views.
    /// Returning nil stops the walk immediately.
    override var previousValidKeyView: NSView? { nil }
    override var nextValidKeyView: NSView? { nil }

    /// Callback invoked when terminal receives a bell (BEL character)
    var onBell: (() -> Void)?

    /// When true, becomeFirstResponder/resignFirstResponder suppress
    /// focus in/out escape sequences (mode 1004) to the PTY. Set during
    /// internal session switching to prevent Claude Code from responding
    /// to focus events and triggering false busy state.
    /// Self-clearing: each responder method clears its own flag after use.
    var suppressFocusEvents = false

    // MARK: - First Responder (focus event suppression)

    public override func becomeFirstResponder() -> Bool {
        let savedSendFocus = terminal.sendFocus
        if suppressFocusEvents {
            terminal.sendFocus = false
        }
        let result = super.becomeFirstResponder()
        terminal.sendFocus = savedSendFocus
        suppressFocusEvents = false
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let savedSendFocus = terminal.sendFocus
        if suppressFocusEvents {
            terminal.sendFocus = false
        }
        let result = super.resignFirstResponder()
        terminal.sendFocus = savedSendFocus
        suppressFocusEvents = false
        return result
    }

    // MARK: - Bell

    /// Override bell() to intercept bell events without replacing terminalDelegate
    /// We don't call super.bell() because we handle all bell behavior through onBell callback
    public override func bell(source: Terminal) {
        onBell?()
    }

    // MARK: - Scroll Interception

    /// Callback invoked on scroll-wheel-up before the parent handles
    /// the event. Returns true if the event was consumed (scrollback
    /// overlay created), false to let the parent proceed normally.
    var onScrollUp: ((NSEvent) -> Bool)?

    /// Callback invoked after a scroll motion that moved `yDisp`
    /// downward. Source-agnostic — fires for trackpad, mouse wheel,
    /// scroller knob, and Page Down because every path lands in
    /// `scrollTo`. Used by `TerminalHostView` to snap to the bottom
    /// when the user lands within a couple of rows, fixing the
    /// fractional-accumulator slop that otherwise leaves yDisp short
    /// of yBase and `userScrolling` stuck true.
    var onScrollDown: (() -> Void)?

    public override func scrollWheel(with event: NSEvent) {
        if event.deltaY > 0, let callback = onScrollUp, callback(event) {
            return
        }
        super.scrollWheel(with: event)
    }

    /// Override the canonical scroll funnel. Every motion (wheel,
    /// page, scroller knob, programmatic) lands here, so a single
    /// post-call check covers all entry points. Capture yDisp before
    /// super so we can detect direction and only fire the down-snap
    /// callback when the viewport actually moved toward the bottom.
    public override func scrollTo(
        row: Int, notifyAccessibility: Bool = true
    ) {
        let before = terminal.displayBuffer.yDisp
        super.scrollTo(
            row: row, notifyAccessibility: notifyAccessibility
        )
        if terminal.displayBuffer.yDisp > before {
            onScrollDown?()
        }
    }

    /// If `yDisp` is within `rows` of `yBase` but short of
    /// it, snap to bottom and clear `userScrolling` so
    /// `Terminal.scroll()` resumes pinning yDisp = yBase on
    /// every feed. No-op when at bottom, far from bottom, or
    /// while a selection is active (selection.active owns
    /// userScrolling and freezes the viewport — see
    /// `selectionChanged` in MacTerminalView).
    @discardableResult
    func snapViewportToBottomIfWithin(rows: Int) -> Bool {
        let buf = terminal.displayBuffer
        guard !selection.active else { return false }
        guard buf.yDisp < buf.yBase else { return false }
        guard buf.yDisp >= buf.yBase - rows else { return false }
        terminal.userScrolling = false
        buf.yDisp = buf.yBase
        terminal.refresh(startRow: 0, endRow: terminal.rows)
        setNeedsDisplay(bounds)
        return true
    }
}
