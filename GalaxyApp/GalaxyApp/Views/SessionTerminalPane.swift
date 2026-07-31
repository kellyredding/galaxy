import AppKit
import Combine
import Galactic

/// `TerminalPane` conformer that wraps a `TerminalBackend` +
/// `Session`. Used for the top (Session) pane in the Terminal
/// tab.
///
/// Thin adapter — zero behavior change. All Claude-specific
/// behavior (busy monitor, turn state, ledger enrichment,
/// resume-marker polling, command verification) stays on
/// `Session`. This type just exposes the backend via the
/// `TerminalPane` protocol so `TerminalHostView` can be used
/// generically across pane kinds.
final class SessionTerminalPane: TerminalPane {
    weak var session: Session?
    let backend: TerminalBackend

    var view: NSView { backend.view }
    var paneKind: TerminalPaneKind { .session }
    var ledgerSessionId: Int64? { session?.ledgerSessionId }

    /// Session pane ignores this — `Session`'s own exit
    /// handling (via `TerminalProcessHandler`) is the
    /// source of truth.
    var onProcessExit: ((Int32) -> Void)?

    /// Session pane ignores this — `SessionManager` wires
    /// `backend.onBell` directly to its bell pipeline.
    /// Do NOT double-install from here.
    var onBell: (() -> Void)?

    /// Scroll-up interception forwards to the backend, which
    /// fires it from its underlying scroll-wheel override.
    var onScrollUp: ((NSEvent) -> Bool)? {
        get { backend.onScrollUp }
        set { backend.onScrollUp = newValue }
    }

    var hasScrollbackContent: Bool {
        backend.hasScrollbackContent
    }

    var viewportRow: Int { backend.viewportRow }

    func clearSelection() { backend.clearSelection() }

    var font: NSFont { backend.font }

    var cellHeight: CGFloat { backend.cellHeight }

    func redraw() { backend.redraw() }

    func snapViewportToBottom() {
        backend.snapViewportToBottom()
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

    /// Session-pane font size lives on the Session model so
    /// it persists across pane teardown (e.g. resume). Forward
    /// to the existing per-session mutators so the publisher
    /// fires and any subscribed views (TerminalHostView's
    /// scrollback overlay, etc.) re-render.
    func increaseFontSize() {
        session?.increaseTerminalFontSize()
    }

    func decreaseFontSize() {
        session?.decreaseTerminalFontSize()
    }

    func resetFontSize() {
        session?.resetTerminalFontSize()
    }

    var canIncreaseFontSize: Bool {
        session?.canIncreaseTerminalFontSize ?? false
    }

    var canDecreaseFontSize: Bool {
        session?.canDecreaseTerminalFontSize ?? false
    }

    init(session: Session, backend: TerminalBackend) {
        self.session = session
        self.backend = backend
    }

    func captureScrollbackSnapshot() -> ScrollbackSnapshot? {
        backend.captureScrollbackSnapshot()
    }

    func send(text: String, asPaste: Bool) {
        backend.send(text: text, asPaste: asPaste)
    }

    func trimBuffer() { backend.trimBuffer() }

    func reflowBuffer() { backend.reflowBuffer() }

    func reassertFollowIfIntended() { backend.reassertFollowIfIntended() }

    func focus() {
        backend.focus()
    }

    var acceptsFileDrops: Bool {
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
                send: { _ in },
                disabledReason: { "Resume the session first" }
            )
        }
        return SendToClaudeTarget(
            // Not verified: a person is watching this one land, and can press
            // their own submit key if it does not. The retry exists for prompts
            // Galaxy sends while nobody is looking.
            send: { [weak s] text in
                s?.sendCommand(text, verifyAccepted: false)
            },
            disabledReason: { nil }
        )
    }
}
