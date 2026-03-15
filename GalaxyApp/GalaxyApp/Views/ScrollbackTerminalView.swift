import AppKit
import SwiftTerm

/// Read-only TerminalView subclass that displays a frozen snapshot of the
/// terminal buffer. Subclasses TerminalView (MacTerminalView.swift) directly —
/// NOT LocalProcessTerminalView — so no LocalProcess is created and
/// terminalDelegate stays nil.
///
/// PTY interaction is disabled via five redundant layers:
///   1. keyDown never calls super (primary)
///   2. paste: is overridden as no-op
///   3. allowMouseReporting = false
///   4. terminalDelegate is nil (no process created)
///   5. send(data:) is overridden as no-op (belt-and-suspenders)
class ScrollbackTerminalView: TerminalView {
    /// Short-circuit key view traversal — same fix as GalaxyTerminalView.
    /// Without this, session switching while scrollback is first responder
    /// causes AppKit to walk thousands of SwiftUI-managed views (beach ball).
    override var previousValidKeyView: NSView? { nil }
    override var nextValidKeyView: NSView? { nil }

    /// Called when the user presses Escape to dismiss the scrollback overlay.
    var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)

        // Disable mouse reporting — prevent mouseDown/mouseDragged/mouseUp
        // from reaching the sharedMouseEvent → send() path.
        allowMouseReporting = false

        // Hide the caret so there's no double cursor with the live terminal.
        // The focus notification observers still fire but setNeedsDisplay on a
        // hidden view is a rendering no-op.
        caretView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - PTY Isolation

    /// No-op — prevents ensureCaretIsVisible() viewport snapping and
    /// accidental data send. Belt-and-suspenders: even if a future code
    /// path bypasses our other guards, this override prevents data from
    /// being sent.
    override func send(data: ArraySlice<UInt8>) {
        // Intentionally empty — read-only view
    }

    /// Resize the snapshot buffer with scroll-position anchoring.
    /// The snapshot is wired as normalBuffer so resizeBuffers() hits
    /// the right object. Skips softReset() (which super calls) to
    /// preserve snapshot state.
    override func resize(cols: Int, rows: Int) {
        let buf = terminal.buffer
        let scrollFraction = buf.yBase > 0
            ? Double(buf.yDisp) / Double(buf.yBase)
            : 1.0

        terminal.resize(cols: cols, rows: rows)

        // Restore scroll position proportionally after reflow
        let newYDisp = Int(scrollFraction * Double(buf.yBase))
        terminal.setViewYDisp(newYDisp)
    }

    // MARK: - Keyboard Handling

    /// Custom keyDown that never calls super. This prevents:
    ///   - selection.active = false (line 813 in MacTerminalView)
    ///   - interpretKeyEvents → insertText → send(txt:)
    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers else { return }
        guard let scalar = chars.unicodeScalars.first else { return }

        let keyCode = Int(scalar.value)

        switch keyCode {
        case 0x1B:  // Escape
            onDismiss?()

        case NSUpArrowFunctionKey:
            scrollUp(lines: 1)

        case NSDownArrowFunctionKey:
            scrollDown(lines: 1)

        case NSPageUpFunctionKey:
            scrollUp(lines: terminal.rows)

        case NSPageDownFunctionKey:
            scrollDown(lines: terminal.rows)

        case NSHomeFunctionKey:
            scrollTo(row: 0)

        case NSEndFunctionKey:
            scrollTo(row: terminal.displayBuffer.yBase)

        default:
            break  // Silently ignore all other keys
        }
    }

    // MARK: - Menu Action Overrides

    /// Copy selection without clearing it. The inherited implementation calls
    /// selectNone() after copy, which makes sense for the live terminal but is
    /// wrong for a read-only view where the user may want to keep the selection.
    @objc override func copy(_ sender: Any) {
        guard selection.active else { return }  // Silent no-op if nothing selected

        let str = selection.getSelectedText()
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(str, forType: .string)
        // Intentionally do NOT call selection.selectNone()
    }

    /// No-op — paste has no meaning in a read-only view. Prevents the inherited
    /// path from calling insertText → send().
    @objc override func paste(_ sender: Any) {
        // Intentionally empty
    }
}
