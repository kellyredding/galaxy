import AppKit
import SwiftTerm

/// Custom terminal view that extends LocalProcessTerminalView.
/// This allows us to intercept terminal events (like bell) without
/// replacing the terminalDelegate, which breaks SwiftTerm's internal behavior.
class GalaxyTerminalView: LocalProcessTerminalView {
    /// Disable custom block glyph rendering on construction so
    /// block elements (U+2580–U+259F) and box drawing
    /// (U+2500–U+257F) fall through to CoreText font rendering,
    /// matching Terminal.app. Baked into init so callers don't
    /// have to remember to set it. Also installs an internal
    /// `DelegateProxy` as the `processDelegate` so SwiftTerm's
    /// process-lifecycle callbacks fire into Galaxy-typed event
    /// hooks (`onProcessTerminated`) instead of routing through
    /// a separate sidecar handler defined elsewhere.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.customBlockGlyphs = false
        self.delegateProxy.owner = self
        self.processDelegate = self.delegateProxy
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.customBlockGlyphs = false
        self.delegateProxy.owner = self
        self.processDelegate = self.delegateProxy
    }

    /// Called when the child process exits. Set by
    /// `SessionManager.wireSessionCallbacks`. Mirrors
    /// `SwiftTermBackend.onProcessTerminated` for symmetry.
    var onProcessTerminated: ((Int32) -> Void)?

    /// Internal delegate proxy. SwiftTerm's
    /// `LocalProcessTerminalView` already implements (non-open)
    /// stubs of the delegate methods on the class itself, so a
    /// subclass can't directly conform to the protocol and
    /// implement them without override conflicts. A separate
    /// proxy object sidesteps this entirely and keeps the
    /// SwiftTerm-typed delegate signatures off `GalaxyTerminalView`'s
    /// interface.
    private let delegateProxy = DelegateProxy()

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

    /// Routes SwiftTerm's `LocalProcessTerminalViewDelegate`
    /// callbacks into the owning `GalaxyTerminalView`'s
    /// Galaxy-typed event hooks. Lives as a sidecar object
    /// because the SwiftTerm class already implements (non-open)
    /// stubs of these methods, blocking direct conformance from
    /// a subclass.
    fileprivate final class DelegateProxy: NSObject,
        LocalProcessTerminalViewDelegate {
        weak var owner: GalaxyTerminalView?

        func processTerminated(
            source: SwiftTerm.TerminalView, exitCode: Int32?
        ) {
            owner?.onProcessTerminated?(exitCode ?? -1)
        }

        func sizeChanged(
            source: SwiftTerm.LocalProcessTerminalView,
            newCols: Int, newRows: Int
        ) {
            // SwiftTerm reflows internally; nothing for Galaxy
            // to do.
        }

        func setTerminalTitle(
            source: SwiftTerm.LocalProcessTerminalView,
            title: String
        ) {
            // Galaxy doesn't display per-pane terminal titles.
        }

        func hostCurrentDirectoryUpdate(
            source: SwiftTerm.TerminalView, directory: String?
        ) {
            // Galaxy doesn't track per-pane cwd.
        }
    }
}

extension GalaxyTerminalView {
    /// Install a 16-color ANSI palette using Galaxy's backend-
    /// agnostic palette type. Wraps SwiftTerm's
    /// `installColors([SwiftTerm.Color])` with conversion at the
    /// boundary so callers (e.g. `Session.applyColorTheme`) don't
    /// need to name SwiftTerm types.
    func installColors(_ palette: [TerminalPaletteColor]) {
        let swiftTermPalette = palette.map {
            SwiftTerm.Color(
                red: $0.red, green: $0.green, blue: $0.blue
            )
        }
        installColors(swiftTermPalette)
    }
}
