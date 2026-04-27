import AppKit
import Combine
import SwiftTerm

/// `TerminalPane` conformer that wraps an existing
/// `GalaxyTerminalView` + `Session`. Used for the top
/// (Session) pane in the Terminal tab.
///
/// Thin adapter — zero behavior change. All Claude-specific
/// behavior (busy monitor, turn state, ledger enrichment,
/// resume-marker polling, command verification) stays on
/// `Session` and `GalaxyTerminalView`. This type just
/// exposes them via the `TerminalPane` protocol so
/// `TerminalHostView` can be generalized in Phase 1c.
///
/// Defined but not wired in Phase 1b — no call site
/// constructs a `SessionTerminalPane` yet.
final class SessionTerminalPane: TerminalPane {
    weak var session: Session?
    let galaxyView: GalaxyTerminalView

    var view: NSView { galaxyView }
    var paneKind: String { "session" }
    var ledgerSessionId: Int64? { session?.ledgerSessionId }

    /// Session pane ignores this — `Session`'s own exit
    /// handling (via `TerminalProcessHandler`) is the
    /// source of truth.
    var onProcessExit: ((Int32) -> Void)?

    /// Session pane ignores this — `SessionManager` wires
    /// `galaxyView.onBell` directly to its bell pipeline.
    /// Do NOT double-install from here.
    var onBell: (() -> Void)?

    /// Scroll-up interception forwards to
    /// `GalaxyTerminalView.onScrollUp`, which fires from its
    /// `scrollWheel` override.
    var onScrollUp: ((NSEvent) -> Bool)? {
        get { galaxyView.onScrollUp }
        set { galaxyView.onScrollUp = newValue }
    }

    /// Scroll-down notification forwards to
    /// `GalaxyTerminalView.onScrollDown`, which fires from
    /// its `scrollTo` override after any motion that moved
    /// `yDisp` downward. Same delegation pattern as
    /// `onScrollUp`.
    var onScrollDown: (() -> Void)? {
        get { galaxyView.onScrollDown }
        set { galaxyView.onScrollDown = newValue }
    }

    func snapViewportToBottomIfWithin(rows: Int) -> Bool {
        galaxyView.snapViewportToBottomIfWithin(rows: rows)
    }

    var hasScrollbackContent: Bool {
        galaxyView.terminal.displayBuffer.yBase > 0
    }

    var viewportRow: Int {
        galaxyView.terminal.displayBuffer.yDisp
    }

    func clearSelection() {
        galaxyView.selection.selectNone()
    }

    /// Session pane reads font size from the owning Session
    /// (per-session `@Published`). Returns 0 if the session
    /// has been deallocated — should not happen in practice
    /// because a Session pane only exists while the Session
    /// is running.
    var fontSize: CGFloat {
        session?.terminalFontSize ?? 0
    }

    var fontSizePublisher: AnyPublisher<CGFloat, Never> {
        session?.$terminalFontSize.eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()
    }

    init(session: Session, galaxyView: GalaxyTerminalView) {
        self.session = session
        self.galaxyView = galaxyView
    }

    func snapshotBuffer() -> Buffer? {
        galaxyView.terminal.snapshotBuffer(
            galaxyView.terminal.buffer
        )
    }

    func send(text: String) {
        galaxyView.send(txt: text)
    }

    func focus() {
        galaxyView.window?.makeFirstResponder(galaxyView)
    }

    var isAcceptingInput: Bool {
        guard let s = session else { return false }
        return s.isRunning && !s.hasExited
    }

    /// Session pane's Send-to-Claude routes pastes to its
    /// own terminal. Disabled with a "Resume the session
    /// first" tooltip when the session isn't running —
    /// matches existing behavior today and keeps the
    /// button visible rather than hiding it.
    var sendToClaudeTarget: SendToClaudeTarget? {
        guard let s = session,
              s.isRunning,
              !s.hasExited else {
            return SendToClaudeTarget(
                sendText: { _ in },
                sendCR: { },
                disabledReason: { "Resume the session first" }
            )
        }
        let view = galaxyView
        return SendToClaudeTarget(
            sendText: { text in view.send(txt: text) },
            sendCR: { view.send([0x0D]) },
            disabledReason: { nil }
        )
    }
}
