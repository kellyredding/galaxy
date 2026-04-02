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

    /// Timestamp of the last mouse-motion event sent to the PTY.
    /// Used by dataReceived to suppress busy-state detection for
    /// PTY output that is merely Claude Code's TUI redrawing in
    /// response to mouse tracking (mode 1003). Without this,
    /// every mouse movement over the terminal triggers a false
    /// idle→busy→idle cycle that flashes the status dot.
    private var lastMouseMotionSend: CFAbsoluteTime = 0

    /// How long after a mouse-motion send to suppress busy
    /// detection on incoming PTY data. 100ms is long enough to
    /// cover the round-trip (motion escape → TUI redraw → PTY
    /// output) but short enough that a real response starting
    /// mid-mouse-movement registers within one debounce tick.
    private static let mouseMotionSuppressionWindow: CFAbsoluteTime = 0.1

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

    public override func scrollWheel(with event: NSEvent) {
        if event.deltaY > 0, let callback = onScrollUp, callback(event) {
            return
        }
        super.scrollWheel(with: event)
    }

    // MARK: - Mouse Motion Suppression

    /// Track mouse-motion sends so dataReceived can suppress
    /// busy detection for TUI redraws caused by mouse tracking.
    /// Only motion events are suppressed — clicks (mouseDown/
    /// mouseUp) can trigger real work and must not be suppressed.
    public override func mouseMoved(with event: NSEvent) {
        if terminal.mouseMode.sendMotionEvent() {
            lastMouseMotionSend = CFAbsoluteTimeGetCurrent()
        }
        super.mouseMoved(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        if terminal.mouseMode.sendMotionEvent() {
            lastMouseMotionSend = CFAbsoluteTimeGetCurrent()
        }
        super.mouseDragged(with: event)
    }

    // MARK: - PTY Activity

    /// Override dataReceived to track PTY output activity
    /// for the hybrid content monitor. Does not directly
    /// trigger busy state — the poll cycle is the sole
    /// driver of busy transitions via onDataReceived.
    ///
    /// Mouse-originated PTY echo is excluded so it cannot
    /// sustain the gate during idle periods.
    public override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        let elapsed = CFAbsoluteTimeGetCurrent()
            - lastMouseMotionSend
        if elapsed > Self.mouseMotionSuppressionWindow {
            ptyActiveSinceLastPoll = true
        }
    }

    // MARK: - Hybrid Content Monitor
    //
    // Combines buffer content polling with PTY activity
    // tracking to detect busy state. Buffer content
    // change in the output zone opens a "gate" that
    // allows PTY activity to sustain the busy signal.
    // This bridges gaps where the visible monitor window
    // is momentarily stable but Claude is still streaming
    // escape sequences. The gate closes when both PTY
    // and buffer are quiet for idleTailTicks consecutive
    // polls.

    /// Hash of character content in the monitoring zone
    /// from the last poll cycle.
    private var monitorContentHash: Int = 0

    /// Timer for periodic buffer content polling.
    private var contentPollTimer: Timer?

    /// Gate flag: true when buffer content has changed,
    /// allowing PTY activity to sustain busy state.
    private var contentGateOpen: Bool = false

    /// Set by dataReceived when non-mouse PTY data
    /// arrives. Cleared each poll cycle after checking.
    private var ptyActiveSinceLastPoll: Bool = false

    /// Consecutive poll ticks where both buffer is stable
    /// and PTY is quiet. Must reach idleTailTicks before
    /// closing the gate.
    private var quietTickCount: Int = 0

    private static let pollInterval: TimeInterval = 0.2
    private static let monitorRowCount: Int = 20
    private static let inputScanLimit: Int = 15
    /// Consecutive quiet polls required before closing
    /// the gate (3 ticks × 200ms = 600ms tail).
    private static let idleTailTicks: Int = 3
    /// U+2500 BOX DRAWINGS LIGHT HORIZONTAL (─)
    private static let boxHorizontal: Int32 = 0x2500

    /// Start polling buffer content. Call after terminal
    /// is set up and the process is running.
    func startContentMonitor() {
        contentPollTimer?.invalidate()
        contentPollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.pollBufferContent()
        }
    }

    /// Stop polling. Call during session teardown.
    func stopContentMonitor() {
        contentPollTimer?.invalidate()
        contentPollTimer = nil
    }

    private func pollBufferContent() {
        let buffer = terminal.displayBuffer
        let rows = terminal.rows
        let cols = terminal.cols
        guard rows > 0, cols > 0 else { return }

        // --- Detect input area boundary ---
        // Scan from bottom for the ─ / content / ─
        // sandwich pattern.
        var bottomBorderRow: Int? = nil
        var topBorderRow: Int? = nil
        let scanStart = rows - 1
        let scanEnd = max(0, rows - Self.inputScanLimit)

        for row in stride(
            from: scanStart,
            through: scanEnd,
            by: -1
        ) {
            let line = buffer.lines[buffer.yBase + row]
            let firstChar = line[0].code
            if firstChar == Self.boxHorizontal {
                if bottomBorderRow == nil {
                    bottomBorderRow = row
                } else {
                    topBorderRow = row
                    break
                }
            }
        }

        let monitorEnd: Int
        if let tb = topBorderRow {
            // Skip 1 row above the top border — Claude's
            // TUI sometimes updates the row just above
            // the input area (companion art, status hints)
            // which isn't an indication of busyness.
            monitorEnd = tb - 2
        } else {
            // Fallback: fixed offset from bottom
            monitorEnd = rows - 8
        }

        let monitorStart = max(
            0, monitorEnd - Self.monitorRowCount + 1
        )
        guard monitorStart <= monitorEnd else { return }

        // --- Hash character content (codes only) ---
        var hasher = Hasher()
        for row in monitorStart...monitorEnd {
            let line = buffer.lines[buffer.yBase + row]
            for col in 0..<cols {
                hasher.combine(line[col].code)
            }
        }
        let newHash = hasher.finalize()

        let contentChanged = newHash != monitorContentHash
            && monitorContentHash != 0
        monitorContentHash = newHash

        // Snapshot and reset PTY activity flag
        let hadPtyActivity = ptyActiveSinceLastPoll
        ptyActiveSinceLastPoll = false

        // --- Hybrid gate logic ---
        if contentChanged || hadPtyActivity {
            // Either signal is active → reset quiet
            // countdown and ensure gate is set.
            quietTickCount = 0

            if contentChanged {
                contentGateOpen = true
            }

            if contentGateOpen {
                onDataReceived?()
            }
        } else if contentGateOpen {
            // Both quiet — increment countdown
            quietTickCount += 1
            if quietTickCount >= Self.idleTailTicks {
                contentGateOpen = false
                quietTickCount = 0
            }
        }
    }

}
