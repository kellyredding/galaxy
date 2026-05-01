import AppKit
import SwiftTerm

/// Custom terminal view that extends LocalProcessTerminalView.
/// Intercepts terminal events (bell, scroll) without replacing
/// `terminalDelegate`, which would break SwiftTerm's internal
/// behavior. Process-lifecycle delegation is handled by the
/// owning `SwiftTermBackend` (which conforms to
/// `LocalProcessTerminalViewDelegate` and assigns itself as
/// `processDelegate` after constructing this view).
class GalaxySwiftTermView: LocalProcessTerminalView {
    /// Disable custom block glyph rendering on construction so
    /// block elements (U+2580–U+259F) and box drawing
    /// (U+2500–U+257F) fall through to CoreText font rendering,
    /// matching Terminal.app. Baked into init so callers don't
    /// have to remember to set it.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.customBlockGlyphs = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.customBlockGlyphs = false
    }

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

extension GalaxySwiftTermView {
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

    /// Set the default foreground color. Wraps SwiftTerm's
    /// `nativeForegroundColor` property so callers
    /// (e.g. `Session.applyColorTheme`) interact through a
    /// Galaxy-named method instead of a SwiftTerm property.
    func setForegroundColor(_ color: NSColor) {
        nativeForegroundColor = color
    }

    /// Set the default background color. Wraps SwiftTerm's
    /// `nativeBackgroundColor` property — Galaxy-named method
    /// surface mirroring `setForegroundColor`.
    func setBackgroundColor(_ color: NSColor) {
        nativeBackgroundColor = color
    }

    /// Set the bold foreground color. Wraps the vendor-patched
    /// `galaxyBoldForegroundColor` property so callers don't
    /// reference the patch-specific name directly.
    func setBoldForegroundColor(_ color: NSColor) {
        galaxyBoldForegroundColor = color
    }

    /// Change the scrollback line cap at runtime. Wraps
    /// SwiftTerm's `terminal.changeHistorySize(_:)` so callers
    /// don't reach through `.terminal` (a SwiftTerm-typed
    /// intermediate) to hit the underlying buffer.
    func changeHistorySize(_ lines: Int) {
        terminal.changeHistorySize(lines)
    }

    /// Set the active terminal font. Wraps the inherited
    /// `font` property write so the call site reads as a
    /// Galaxy-named operation rather than a SwiftTerm property
    /// assignment.
    func setFont(_ font: NSFont) {
        self.font = font
    }

    /// Send text to the PTY using the Galaxy-named `text:`
    /// label. Wraps SwiftTerm's `send(txt:)` so call sites
    /// match the convention used on the `TerminalBackend`
    /// protocol and `pane.send(text:asPaste:)`.
    func send(text: String) {
        send(txt: text)
    }

    /// Send raw bytes to the PTY using the Galaxy-named
    /// `bytes:` label. Wraps SwiftTerm's unlabeled
    /// `send(_:)` so call sites read consistently with the
    /// rest of the IO surface.
    func send(bytes: [UInt8]) {
        send(bytes)
    }

    /// Send text to the PTY, with bracketed-paste-mode
    /// wrapping when both `asPaste` is true and the terminal
    /// has bracketed-paste-mode enabled. Mirrors
    /// `SwiftTermBackend.send(text:asPaste:)` so the chrome
    /// has a single uniform entry point regardless of which
    /// pane it's hosting.
    func send(text: String, asPaste: Bool) {
        if asPaste, terminal.bracketedPasteMode {
            send(Array(EscapeSequences.bracketedPasteStart))
            send(txt: text)
            send(Array(EscapeSequences.bracketedPasteEnd))
        } else {
            send(txt: text)
        }
    }

    /// True when the scrollback buffer has content above the
    /// viewport. Wraps the SwiftTerm read so callers don't
    /// reach through `.terminal.displayBuffer.yBase` (a
    /// chain of three SwiftTerm-typed intermediates).
    var hasScrollbackContent: Bool {
        terminal.displayBuffer.yBase > 0
    }

    /// Current viewport top row (`yDisp`). Used by chrome as
    /// the initial scroll position when opening the
    /// scrollback overlay so the overlay opens at the user's
    /// current view rather than at the bottom.
    var viewportRow: Int {
        terminal.displayBuffer.yDisp
    }

    /// Clear any active text selection. Wraps SwiftTerm's
    /// `selection.selectNone()` so callers don't reach
    /// through the SwiftTerm-typed selection service.
    func clearSelection() {
        selection.selectNone()
    }

    /// Unconditionally snap the viewport to the bottom of
    /// the scrollback buffer (`yDisp = yBase`) and clear the
    /// `userScrolling` gate so subsequent output auto-
    /// follows. Distinct from `snapViewportToBottomIfWithin`
    /// — no threshold, no selection-active guard, no return
    /// value. Mirrors `SwiftTermBackend.snapViewportToBottom`
    /// shape-for-shape.
    func snapViewportToBottom() {
        let buf = terminal.displayBuffer
        terminal.userScrolling = false
        buf.yDisp = buf.yBase
        setNeedsDisplay(bounds)
    }

    /// Capture the current scrollback buffer as a Galaxy-
    /// typed `ScrollbackSnapshot` — opaque from the chrome's
    /// POV. Wraps SwiftTerm's `terminal.snapshotBuffer(_:)`
    /// and the `SwiftTermScrollbackSnapshot` initializer so
    /// callers don't need to name SwiftTerm types or know
    /// which concrete snapshot impl pairs with this view.
    func captureScrollbackSnapshot() -> ScrollbackSnapshot? {
        let buffer = terminal.snapshotBuffer(terminal.buffer)
        return SwiftTermScrollbackSnapshot(
            buffer: buffer, terminal: terminal
        )
    }
}
