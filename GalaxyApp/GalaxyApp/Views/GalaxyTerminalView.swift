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

    /// Callback invoked when PTY output is received (for busy state detection)
    var onDataReceived: (() -> Void)?

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

    // MARK: - PTY Activity

    /// Override dataReceived to detect PTY output activity.
    /// Fires on SwiftTerm's dispatch queue — callers must dispatch to main for UI updates.
    public override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onDataReceived?()
    }

    // MARK: - Scroll Interception

    /// Callback invoked on scroll-wheel-up before the parent handles
    /// the event. Returns true if the event was consumed (scrollback
    /// overlay created), false to let the parent proceed normally.
    /// The NSEvent is passed so the callback can inspect deltaY, phase, etc.
    var onScrollUp: ((NSEvent) -> Bool)?

    public override func scrollWheel(with event: NSEvent) {
        // Only intercept upward scrolls (positive deltaY)
        if event.deltaY > 0, let callback = onScrollUp, callback(event) {
            return  // Scrollback was created, event consumed
        }
        super.scrollWheel(with: event)
    }

    // MARK: - Drag Selection Interception

    /// Callback invoked on the first mouseDragged during a text selection.
    /// Returns the scrollback terminal view to forward remaining drag events
    /// to, or nil if scrollback was not created. When a target is returned,
    /// all subsequent mouseDragged/mouseUp events for this gesture are
    /// forwarded to the scrollback view instead of the live terminal.
    var onDragSelectionStart: ((NSEvent) -> NSView?)?

    /// Target view for forwarding drag events after scrollback creation.
    /// Set on the first mouseDragged when scrollback is triggered, cleared
    /// on mouseUp.
    private var dragForwardTarget: NSView?

    /// Tracks whether the drag-selection callback has fired for the
    /// current gesture. Reset on mouseUp.
    private var dragSelectionFired = false

    public override func mouseDragged(with event: NSEvent) {
        // Forward to scrollback view if already handed off
        if let target = dragForwardTarget {
            target.mouseDragged(with: event)
            return
        }

        // Try to trigger scrollback on first drag movement
        if !dragSelectionFired, let callback = onDragSelectionStart {
            dragSelectionFired = true
            if let target = callback(event) {
                dragForwardTarget = target
                // Synthesize mouseDown to prime selection tracking in
                // the scrollback view, then immediately send the drag
                target.mouseDown(with: event)
                target.mouseDragged(with: event)
                return
            }
        }

        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if let target = dragForwardTarget {
            target.mouseUp(with: event)
            dragForwardTarget = nil
        }
        dragSelectionFired = false
        super.mouseUp(with: event)
    }
}
