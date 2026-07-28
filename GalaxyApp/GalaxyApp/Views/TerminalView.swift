import SwiftUI
import AppKit
import Combine
import Galactic

extension Notification.Name {
    static let enterScrollback = Notification.Name("enterScrollback")
}

// Direct NSView wrapper with explicit focus handling. Accepts
// any TerminalPane conformer so both the Session pane
// (SessionTerminalPane) and the coming Shell pane
// (ShellTerminalPane, Phase 2) share the same SwiftUI→AppKit
// bridge without branching.
struct FocusableTerminalView: NSViewRepresentable {
    let pane: TerminalPane
    let isActive: Bool

    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(pane: pane)
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        let wasActive = nsView.isActive
        let activationChanged = isActive != wasActive

        // didSet on isActive runs updateDragRegistration when
        // the value flips (guarded by != oldValue). Only call
        // refreshDragRegistration explicitly when isActive
        // didn't flip — that's the case where
        // pane.acceptsFileDrops may have changed and the
        // didSet path skipped. Avoids paying for two
        // register/unregister cycles per transition row.
        nsView.isActive = isActive
        if !activationChanged {
            nsView.refreshDragRegistration()
        }

        if !isActive {
            // If we're deactivating AND this host holds first
            // responder (i.e., the user was typing in this
            // pane), resign first responder EXPLICITLY before
            // flipping isHidden. AppKit's auto-resign path
            // inside -[NSView setHidden:] does ~800ms of
            // synchronous work when the first responder is a
            // descendant of the view being hidden — observed
            // on shell pane session-switch, with cost
            // asymmetric to whether the pane was focused.
            // Resigning first responder ourselves before the
            // hide drops that cost from ~800ms to <1ms. The
            // workaround is backend-agnostic (no SwiftTerm-
            // specific code), so it survives a future
            // libghostty migration unchanged.
            let responder = nsView.window?.firstResponder
            let firstResponderInPane =
                responder === nsView.pane.view
                || (responder as? NSView)?
                    .isDescendant(of: nsView) == true
            if firstResponderInPane {
                nsView.window?.makeFirstResponder(nil)
            }
        }

        // Skip the write when the value already matches —
        // NSView.setHidden does KVO + layer-dirty work even
        // on no-op assignments. After SwiftUI's per-row
        // short-circuit, only the two transition rows
        // actually need this poke.
        let shouldHide = !isActive
        if nsView.isHidden != shouldHide {
            nsView.isHidden = shouldHide
        }

        // Only grab focus on activation transition, not every re-render.
        // Unconditional requestFocus() steals focus from rename TextFields
        // and other non-terminal first responders. Gated through
        // requestFocusIfPreferred() so split-pane sessions (Session +
        // Shell) don't race — only the host matching the session's
        // lastFocusedPaneKind takes focus, leaving the registry's
        // memory intact for TerminalContainerView's onChange-driven
        // restoreTerminalFocus() (which reads the same value).
        if isActive && !wasActive {
            nsView.requestFocusIfPreferred()
        }
    }
}

extension FocusableTerminalView: Equatable {
    /// Identity equality: same pane (by reference) and same
    /// isActive flag. Used via `.equatable()` at call sites
    /// so SwiftUI guarantees `updateNSView` is skipped on
    /// rows whose inputs haven't changed — independent of
    /// SwiftUI's automatic memberwise diff for the
    /// protocol-typed `pane` property, which isn't
    /// guaranteed to compare by reference.
    ///
    /// `pane` is always a class-conforming `TerminalPane`
    /// (`SessionTerminalPane` or `ShellTerminalPane`), so
    /// `as AnyObject` reference equality is well-defined.
    /// `SessionPaneAdapterHolder` caches the adapter per
    /// backend, so the reference flips exactly when
    /// stop/resume creates a new backend — i.e., when we
    /// *want* a re-update.
    static func == (
        lhs: FocusableTerminalView,
        rhs: FocusableTerminalView
    ) -> Bool {
        lhs.isActive == rhs.isActive
            && (lhs.pane as AnyObject) === (rhs.pane as AnyObject)
    }
}

// Container that properly handles focus, drag-drop, and passes
// events to a TerminalPane conformer. The pane abstracts away
// the underlying terminal backend so this view never has to
// know which engine is rendering.
class TerminalHostView: NSView {
    let pane: TerminalPane

    /// Downcast to SessionTerminalPane for Session-pane-specific
    /// behavior (font observers, scrollback unsaved-work checks).
    /// Nil for non-Session panes.
    private var sessionPane: SessionTerminalPane? {
        pane as? SessionTerminalPane
    }

    /// Convenience accessor derived from `sessionPane`. Kept as
    /// an optional because non-Session panes (Shell pane) don't
    /// populate it. Paths that hit it are Session-specific
    /// (Claude-side observers).
    var session: Session? { sessionPane?.session }

    /// The owning session regardless of pane type.
    /// `self.session` above only resolves for the Session
    /// pane; this also reaches through `ShellTerminalPane`
    /// so shared behaviors (e.g. quit-warning checkers)
    /// can cover both panes with one call site.
    private var owningSession: Session? {
        if let sp = sessionPane {
            return sp.session
        }
        if let sp = pane as? ShellTerminalPane {
            return sp.session
        }
        return nil
    }

    // Track if this is the active session - controls drag-drop registration
    var isActive: Bool = false {
        didSet {
            if isActive != oldValue {
                updateDragRegistration()
            }
        }
    }
    private var isSetUp = false

    /// Uniform inset between the host's bounds and the inner
    /// terminal view / scrollback overlay / drag highlight.
    /// The host's layer background is painted in the current
    /// theme color so the inset strip reads as "part of the
    /// pane" rather than chrome.
    private static let terminalPadding: CGFloat = 4

    /// Galactic-owned container that hosts the live terminal
    /// full-bleed inside a `terminalPadding` inset. SwiftTerm clips
    /// its leftmost column whenever the terminal view's own frame
    /// origin is offset from (0,0) of its superview, so the inset
    /// lives on the container, never on the terminal itself.
    /// Created in `setupTerminal` once `pane.view` exists.
    private var terminalContainer: GalacticTerminalContainerView?

    // Drag highlight overlay (drawn on top of terminal)
    private var dragHighlightView: DragHighlightView?

    // Drag-drop state
    private var isReceivingDrag = false {
        didSet {
            dragHighlightView?.isHighlighted = isReceivingDrag
        }
    }

    // Event monitor for Ctrl+Arrow key interception
    private var keyEventMonitor: Any?

    // MARK: - Scrollback State

    /// Exit reason for scrollback timeline events.
    private enum ScrollbackExitReason: String {
        case dismissed
        case reviewed
        case sessionEnded = "session-ended"
        case appQuit = "app-quit"
    }

    /// The scrollback overlay (holds ScrollbackWebView + pill).
    /// Non-nil when scrollback mode is active.
    private var scrollbackOverlay: ScrollbackOverlayView?

    /// Duration identifier for pairing scrollback:entered
    /// and scrollback:exited timeline events. Generated in
    /// createScrollback(), consumed in performScrollbackTeardown().
    private var scrollbackDurationId: String?

    /// Retained scrollback snapshot for settings-change rebuilds while the
    /// overlay is active. The snapshot freezes the buffer at capture time,
    /// so theme/font changes re-render via `ScrollbackHTMLRenderer.render(
    /// snapshot:...)` without re-snapshotting the live (now-moved-on)
    /// terminal. Nil'd on dismiss to release the captured buffer memory.
    private var currentSnapshot: ScrollbackSnapshot?

    /// True when the scrollback overlay is visible.
    var isScrollbackActive: Bool { scrollbackOverlay != nil }

    /// One-shot flag: when scrollback is opened by Cmd+F, the
    /// dispatcher sets this true right before createScrollback,
    /// and the existing onReady callback consumes it to bring up
    /// the find bar after the overlay has finished painting.
    /// Cleared in dismissScrollback as a belt-and-suspenders
    /// guard against the flag persisting if scrollback creation
    /// fails internally.
    private var pendingFindActivation: Bool = false

    /// Cooldown flag — when true, scroll-wheel-up is ignored to prevent
    /// trackpad momentum from immediately re-creating the scrollback view.
    private var scrollbackCooldown = false
    private var scrollbackCooldownTimer: DispatchWorkItem?

    /// Combine subscriptions for live settings sync (font, theme, hasExited).
    private var cancellables = Set<AnyCancellable>()

    /// Subscriptions active only while a scrollback overlay is
    /// open, driving live enable/disable transitions on the
    /// Send-to-Claude button. Cleared in
    /// `performScrollbackTeardown` so timers don't keep firing
    /// after the overlay closes.
    private var sendButtonStateCancellables = Set<AnyCancellable>()

    /// KVO on `window.firstResponder` driving the focus-
    /// aware dim of:
    ///   1. `pane.view.alphaValue` — the live terminal
    ///      view fades when this pane loses focus to a
    ///      sibling pane (Session ↔ Shell).
    ///   2. `ScrollbackOverlayView.isPaneFocused` — the
    ///      pill + border tint when a scrollback is open.
    /// Lifetime is the host view's, not the scrollback's,
    /// because pane dim applies whether or not a scrollback
    /// is up. Started in `viewDidMoveToWindow`, invalidated
    /// in `deinit`.
    private var firstResponderObservation: NSKeyValueObservation?

    /// Alpha applied to `pane.view` when this pane has
    /// lost focus to a sibling. Tuned so the unfocused
    /// pane reads as clearly inactive without making text
    /// hard to scan if the user glances over.
    private static let unfocusedPaneAlpha: CGFloat = 0.70

    init(pane: TerminalPane) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        // Note: Don't register for drags here - done dynamically via updateDragRegistration()

        // Set up key event monitor for Ctrl+Arrow → line navigation
        setupKeyEventMonitor()
    }

    deinit {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        cancellables.removeAll()
        scrollbackCooldownTimer?.cancel()
        firstResponderObservation?.invalidate()
        let key = ObjectIdentifier(self)
        owningSession?
            .unregisterScrollbackUnsavedWorkChecker(key)
        owningSession?.unregisterPaneFocusRestorer(key)
    }

    /// Set up local event monitor for two purposes:
    ///
    /// 1. Intercept Ctrl+Arrow → translate to Ctrl+A /
    ///    Ctrl+E for word-style line navigation (matches
    ///    Terminal.app's keyboard shortcuts).
    /// 2. Detect Esc while in-turn on the Session pane —
    ///    record `turn:interrupted` immediately so the
    ///    sidebar dot stops pulsing without waiting on a
    ///    buffer scan or hook (Claude Code does not fire
    ///    a Stop hook on Esc-aborted streams).
    ///
    /// Naturally safe during scrollback: the guard checks
    /// `self.window?.firstResponder === self.pane.view`,
    /// which fails when ScrollbackWebView is first
    /// responder, so no bytes are sent and no interrupt
    /// is recorded.
    private func setupKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Only handle if our terminal is the first responder
            guard self.window?.firstResponder === self.pane.view else { return event }

            // Esc with no modifiers → if a turn is active
            // on this Session pane, record turn:interrupted.
            // Don't consume — Esc still needs to flow to
            // SwiftTerm so Claude Code aborts the stream.
            // Idempotency is via TurnState file deletion
            // inside recordEscapeInterrupt — rapid repeat
            // Escs against the same turn read TurnState
            // as nil and bail without re-recording.
            if event.keyCode == 53,
               event.modifierFlags.intersection([
                   .control, .option, .command, .shift,
               ]).isEmpty,
               let session = self.session,
               session.isInTurn
            {
                SessionManager.shared
                    .recordEscapeInterrupt(for: session)
                return event
            }

            // Only intercept when Control is pressed without Option or Command
            let controlOnly = event.modifierFlags.intersection([.control, .option, .command]) == .control

            if controlOnly {
                switch event.keyCode {
                case 123: // Left arrow → beginning of line (Ctrl+A = 0x01)
                    self.pane.send(text: "\u{01}", asPaste: false)
                    return nil  // Consume the event
                case 124: // Right arrow → end of line (Ctrl+E = 0x05)
                    self.pane.send(text: "\u{05}", asPaste: false)
                    return nil  // Consume the event
                default:
                    break
                }
            }

            return event  // Pass through unhandled events
        }
    }

    /// Register or unregister for drag types based on active state.
    /// Only the active pane in an accepting state should be a drop
    /// target.
    private func updateDragRegistration() {
        if isActive && pane.acceptsFileDrops {
            registerForDraggedTypes([.fileURL])
        } else {
            unregisterDraggedTypes()
        }
    }

    /// Called from updateNSView to refresh drag registration when session state changes
    func refreshDragRegistration() {
        updateDragRegistration()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if !isSetUp && window != nil {
            setupTerminal()
            isSetUp = true
        }

        // Re-bind the first-responder observer to the
        // current window. Handles both add (window
        // assigned) and remove (window goes nil), so the
        // observer only exists while we're actually in a
        // window and can never leak across reattachment.
        startObservingFirstResponder()
    }

    private func setupTerminal() {
        // Paint the host's layer in the current theme background
        // color. Combined with the per-subview inset below, this
        // creates a padded strip around the terminal content that
        // reads as "part of the pane" rather than chrome.
        applyHostBackgroundColor()

        // Host the terminal inside the Galactic inset container: it
        // fills the host and lays the terminal out full-bleed within
        // a terminalPadding inset, so SwiftTerm never sees an offset
        // frame (which clips its left column). Autoresizing is
        // disabled so layout() stays the single source of truth.
        let container = GalacticTerminalContainerView(
            terminalView: pane.view,
            inset: Self.terminalPadding
        )
        container.frame = bounds
        container.autoresizingMask = []
        addSubview(container)
        terminalContainer = container

        // Show the engine's native caret on the session pane — it
        // IS Claude's prompt cursor (Claude does not self-render
        // one, so hiding it left no visible cursor). Its shape and
        // blink follow the shared terminal cursor settings, applied
        // through the backend in Session.configureTerminal. Routed
        // through the backend so the chrome doesn't need to know
        // which engine is underneath.
        sessionPane?.backend.setCaretHidden(false)

        // Scroll-up interception — pane-generic. Both session
        // and shell panes route scroll-up through the pane
        // protocol so we enter scrollback mode uniformly.
        pane.onScrollUp = { [weak self] event in
            self?.handleScrollUp(event: event) ?? false
        }

        // Font-size re-renders for the scrollback overlay —
        // pane-generic. Session pane's size lives on
        // `session.$terminalFontSize`; shell pane's lives on
        // `ShellTerminalPane.$fontSize`. Both publish through
        // `pane.fontSizePublisher`.
        pane.fontSizePublisher
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySettingsToScrollback()
            }
            .store(in: &cancellables)

        // Register this host view's scrollback-unsaved-
        // work checker on the owning session so Cmd+Q /
        // stop-session confirmations cover whichever pane
        // has the open scrollback — not just the Session
        // pane. Paired with `unregister` in `deinit`.
        // Register this host view's scrollback-unsaved-
        // work checker on the owning session, tagged with
        // its pane kind so callers (stop-session vs.
        // quit-app) can filter to the panes whose loss
        // matters in their context. Paired with the
        // unregister in `deinit`.
        if let session = owningSession {
            let kind: Session.ScrollbackPaneKind =
                pane is ShellTerminalPane
                    ? .shell : .session
            let key = ObjectIdentifier(self)
            session.registerScrollbackUnsavedWorkChecker(
                key,
                kind: kind
            ) { [weak self] completion in
                guard let self = self else {
                    completion(false)
                    return
                }
                self.checkScrollbackUnsavedWork(
                    completion: completion
                )
            }

            // Register pane-focus restorer so tab-switch /
            // session-switch / app-becomes-key paths can land
            // the user back on the pane they were last in,
            // not unconditionally on the Session pane.
            session.registerPaneFocusRestorer(
                key, kind: kind
            ) { [weak self] in
                self?.requestFocus()
            }
        }

        if let session = self.session {
            // Observe session process exit — tear down scrollback if process dies.
            // Skip note confirmation — the process is gone so there's nothing
            // to send notes to.
            //
            // No .receive(on: .main) here — processDidExit already sets
            // hasExited on main queue. An extra async hop would let SwiftUI
            // tear down this view (hasExited swaps to StoppedSessionView)
            // before the sink fires, preventing the scrollback:exited event.
            session.$hasExited
                .removeDuplicates()
                .sink { [weak self] exited in
                    if exited {
                        self?.performScrollbackTeardown(
                            reason: .sessionEnded
                        )
                    }
                }
                .store(in: &cancellables)
        }

        // Add drag highlight overlay ON TOP of the terminal
        // container (the terminal is nested inside it, so the
        // highlight orders against the container, its host sibling).
        let highlight = DragHighlightView(frame: bounds)
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight, positioned: .above, relativeTo: container)
        dragHighlightView = highlight

        // Observe font family changes — apply to scrollback view if present
        SettingsManager.shared.$settings
            .map(\.terminalFontFamily)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySettingsToScrollback()
            }
            .store(in: &cancellables)

        // Observe color theme changes — apply to the padded host
        // background so the 4px strip around the terminal tracks
        // the theme, and re-render any active scrollback overlay.
        SettingsManager.shared.$settings
            .map(\.terminalColorThemeName)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyHostBackgroundColor()
                self?.applySettingsToScrollback()
            }
            .store(in: &cancellables)

        // Close scrollback on app quit so the
        // scrollback:exited duration event fires.
        // No .receive(on:) — willTerminate already
        // fires on the main thread, and an async hop
        // would be dropped during app teardown.
        NotificationCenter.default.publisher(
            for: NSApplication
                .willTerminateNotification
        )
            .sink { [weak self] _ in
                self?.performScrollbackTeardown(
                    reason: .appQuit
                )
            }
            .store(in: &cancellables)

        // Observe Cmd+S menu action for scrollback entry
        NotificationCenter.default.publisher(for: .enterScrollback)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.enterScrollbackFromMenu()
            }
            .store(in: &cancellables)

        // Observe Cmd+F find activation. If scrollback is already
        // open in this host, focus its find bar; otherwise open
        // scrollback at the current viewport and queue the find
        // bar to appear once the WebView signals ready.
        SessionManager.shared.$findActivationCounter
            .receive(on: DispatchQueue.main)
            .dropFirst()  // ignore initial value
            .sink { [weak self] _ in
                self?.activateFindOnScrollback()
            }
            .store(in: &cancellables)

        // Re-evaluate find-bar-panel ownership on tab and
        // session changes. The scrollback overlay's
        // `findController.isVisible` survives switches (the
        // overlay isn't torn down when the user leaves the
        // terminal tab), so without this the shared panel
        // remains visible bound to a no-longer-active surface
        // until the user navigates back and explicitly
        // dismisses it. `refreshFindBarPanelPresentation` uses
        // `dismiss(if:)` internally, so when both old and new
        // active surfaces fire their observers, only the truly
        // active one wins.
        SessionManager.shared.$activeTab
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                self?.scrollbackOverlay?
                    .refreshFindBarPanelPresentation()
            }
            .store(in: &cancellables)
        SessionManager.shared.$activeSessionId
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                self?.scrollbackOverlay?
                    .refreshFindBarPanelPresentation()
            }
            .store(in: &cancellables)

        // Observe main-window-becomes-key. SwiftTerm's display
        // refresh appears to stall while the window is inactive;
        // when it regains key, force a redraw so the current
        // buffer state is painted immediately rather than
        // lingering on stale cells until the next mouse/key event.
        // Also re-asserts input focus when the responder chain
        // didn't settle on us — covers the typing-stuck sibling
        // of the stale-render symptom (fix c′).
        NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                guard self.isActive else { return }
                // Only react when our own window became key.
                guard let window =
                    notification.object as? NSWindow,
                      window === self.window else { return }
                pane.redraw()
                // Only the preferred pane re-asserts focus.
                // Without this gate, both the session and shell
                // hosts would race and whichever fired last
                // would steal focus regardless of which pane
                // the user was actually in.
                let myKind: Session.ScrollbackPaneKind =
                    self.pane is ShellTerminalPane
                        ? .shell : .session
                let preferred = self.owningSession?
                    .lastFocusedPaneKind ?? .session
                guard myKind == preferred else { return }
                if window.firstResponder !== self.pane.view {
                    self.requestFocus()
                }
            }
            .store(in: &cancellables)

        // Request focus after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.requestFocus()
        }
    }

    override func layout() {
        super.layout()
        let inner = paddedBounds()
        // The container fills the host and lays the terminal out
        // full-bleed inside its inset; overlays align to that inset
        // rect (which equals paddedBounds / the container's content).
        terminalContainer?.frame = bounds
        dragHighlightView?.frame = inner
        scrollbackOverlay?.frame = inner
    }

    /// Current bounds inset by the terminal padding. Used for
    /// every subview's frame so the host layer's background
    /// color shows through as a uniform padded strip.
    private func paddedBounds() -> NSRect {
        bounds.insetBy(
            dx: Self.terminalPadding,
            dy: Self.terminalPadding
        )
    }

    /// Paint the host's layer in the current theme background
    /// color. Called on setup and on theme changes.
    private func applyHostBackgroundColor() {
        let theme = TerminalColorTheme.theme(
            named: SettingsManager.shared
                .settings.terminalColorThemeName
        )
        wantsLayer = true
        layer?.backgroundColor =
            theme.backgroundColorValue.cgColor
    }

    func requestFocus() {
        guard let window = window else { return }

        // If scrollback is active, make the WKWebView first responder
        // instead of the live terminal — otherwise scrollback is visible but
        // keyboard-dead after session switches.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Only re-pin when focusing the live terminal, never the
            // scrollback overlay — a user reading frozen history must not be
            // snapped to the bottom.
            let focusingLivePane = self.scrollbackOverlay == nil
            let target: NSResponder =
                self.scrollbackOverlay?.scrollbackView.webView
                ?? self.pane.view
            // Friendly re-pin on focus gain (session / tab / app-refocus /
            // pane switch): if the user intends to follow the live tail, snap
            // back to the bottom. Itself a no-op when parked in scrollback or
            // already pinned — see Galactic's reassertFollowIfIntended.
            let reassertFollow = {
                if focusingLivePane { self.pane.reassertFollowIfIntended() }
            }
            if window.makeFirstResponder(target) { reassertFollow(); return }
            // First try lost — retry once next runloop in case a
            // resigning responder elsewhere (closing Settings,
            // app-switch focus restore) hadn't fully released the
            // chain yet. One retry is sufficient; further failures
            // imply a deeper problem to investigate via fix (e).
            DispatchQueue.main.async { [weak window] in
                guard let w = window else { return }
                if w.makeFirstResponder(target) { reassertFollow() }
            }
        }
    }

    /// Like `requestFocus()`, but only when this pane matches
    /// the owning session's `lastFocusedPaneKind`. Used by
    /// `FocusableTerminalView.updateNSView` so the activation-
    /// transition focus restoration honors the user's last
    /// pane choice. Without this gate, both the session and
    /// shell hosts would race on every session switch and the
    /// loser of the race would clobber `lastFocusedPaneKind`
    /// via `refreshFocusState`, defeating the registry.
    func requestFocusIfPreferred() {
        let myKind: Session.ScrollbackPaneKind =
            pane is ShellTerminalPane ? .shell : .session
        let preferred = owningSession?
            .lastFocusedPaneKind ?? .session
        guard myKind == preferred else { return }
        requestFocus()
    }

    // Forward mouse events to request focus
    override func mouseDown(with event: NSEvent) {
        requestFocus()
        // Let the event propagate normally - terminal will get it as first responder
        super.mouseDown(with: event)
    }

    // Don't accept first responder - let terminal be the responder
    override var acceptsFirstResponder: Bool { false }

    // MARK: - Drag and Drop

    /// Check if the pane can accept drops (must be active AND
    /// drop-eligible — for Session pane: running, not exited).
    private var canAcceptDrop: Bool {
        return isActive && pane.acceptsFileDrops
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Reject drops while any modal is presenting over our
        // window: app-modal windows (Settings, New Session,
        // Restore Session via NSApp.runModal) or window-modal
        // sheets (every SheetAlert.confirm — quit, stop-session,
        // discard-notes, artifact/snapshot deletes). Prevents
        // the stale-render bug where a drop accepts the paste
        // bytes but the terminal view doesn't repaint until a
        // later event wakes it. Don't gate on isKeyWindow — for
        // inter-app drags from Finder, the source app stays
        // active so neither of our windows is key during the
        // drag, which would reject every legitimate drop.
        guard !ModalState.isPresenting(over: window) else {
            NSCursor.operationNotAllowed.set()
            return []
        }

        // Dismiss scrollback on file drag entry — if notes exist, show
        // confirmation instead of auto-dismissing
        if isScrollbackActive {
            if scrollbackOverlay?.scrollbackView.hasNotes == true {
                showDismissConfirmation()
                return []
            }
            performScrollbackTeardown(reason: .dismissed)
        }

        guard canAcceptDrop else {
            // Show "not allowed" cursor for stopped sessions
            NSCursor.operationNotAllowed.set()
            return []
        }

        // Validate that we have file URLs
        let dominated = sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ])

        if dominated {
            isReceivingDrag = true
            NSCursor.dragCopy.set()
            return .copy
        }

        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !ModalState.isPresenting(over: window) else {
            NSCursor.operationNotAllowed.set()
            return []
        }

        guard canAcceptDrop else {
            NSCursor.operationNotAllowed.set()
            return []
        }

        NSCursor.dragCopy.set()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isReceivingDrag = false
        NSCursor.arrow.set()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isReceivingDrag = false
        NSCursor.arrow.set()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isReceivingDrag = false
        NSCursor.arrow.set()

        // Defense-in-depth: same modal guard as draggingEntered.
        // AppKit may not route performDragOperation when entered
        // returned []—but if it does, refuse cleanly.
        guard !ModalState.isPresenting(over: window) else {
            return false
        }

        guard canAcceptDrop else {
            return false
        }

        // Focus the window and activate the app when a file is dropped
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        // Extract file URLs from the pasteboard
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            return false
        }

        // Deduplicate URLs by path (some drag sources provide duplicates)
        var seenPaths = Set<String>()
        var uniqueUrls: [URL] = []
        for url in urls {
            let path = url.standardized.path
            if !seenPaths.contains(path) {
                seenPaths.insert(path)
                uniqueUrls.append(url)
            }
        }

        // Send raw paths (like Cmd+V paste) so Claude Code shows gray box treatment
        let pathsText = uniqueUrls.map { $0.path }.joined(separator: " ") + " "

        // Send to terminal with bracketed paste mode
        sendTextToTerminal(pathsText, asPaste: true)

        // Defensive: kick the terminal view to repaint even if
        // we're arriving from a window-inactive state where
        // SwiftTerm's display refresh paused. requestFocus()
        // (not pane.focus()) engages the verified-retry path
        // from b′ so input also revives.
        pane.redraw()
        requestFocus()

        return true
    }

    // MARK: - Scrollback Lifecycle

    /// Handle scroll-wheel-up on the live terminal. Returns true if the event
    /// was consumed (scrollback overlay created), false to let normal scroll proceed.
    private func handleScrollUp(event: NSEvent) -> Bool {
        guard SettingsManager.shared.settings.scrollToEnterScrollback else { return false }
        guard !isScrollbackActive else { return false }
        guard !scrollbackCooldown else { return false }
        guard pane.hasScrollbackContent else { return false }

        let scrollPosition = pane.viewportRow
        pane.clearSelection()
        createScrollback(initialScrollLine: scrollPosition)
        return true
    }

    /// Start the post-dismiss cooldown. Clears on momentum end or ~300ms timeout
    /// (whichever comes first). Prevents trackpad momentum from immediately
    /// re-creating the scrollback view after dismiss.
    private func startScrollbackCooldown() {
        scrollbackCooldown = true
        scrollbackCooldownTimer?.cancel()

        // Monitor for momentum end — clears cooldown early for trackpads
        var momentumMonitor: Any?
        momentumMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if event.momentumPhase == .ended
                || (event.momentumPhase == [] && event.phase == .ended) {
                self?.scrollbackCooldown = false
                self?.scrollbackCooldownTimer?.cancel()
                self?.scrollbackCooldownTimer = nil
                if let monitor = momentumMonitor {
                    NSEvent.removeMonitor(monitor)
                    momentumMonitor = nil
                }
            }
            return event
        }

        // Safety timeout — for discrete mouse wheels that don't send momentum events
        let timer = DispatchWorkItem { [weak self] in
            self?.scrollbackCooldown = false
            self?.scrollbackCooldownTimer = nil
            if let monitor = momentumMonitor {
                NSEvent.removeMonitor(monitor)
                momentumMonitor = nil
            }
        }
        scrollbackCooldownTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: timer)
    }

    /// Enter scrollback mode from Cmd+S menu action. Only the
    /// currently-focused pane should respond — with the split
    /// view, both the Session and Shell panes hear the
    /// notification but we want scrollback only on the one the
    /// user is actually typing into.
    ///
    /// Unlike `handleScrollUp`, we don't require `yBase > 0` here.
    /// Cmd+S is a deliberate user action — even with an empty
    /// scrollback buffer (fresh shell, minimal Claude output),
    /// entering scrollback lets the user annotate what's currently
    /// visible. The scroll-wheel path stays strict to avoid
    /// spamming the overlay on ordinary scroll gestures.
    private func enterScrollbackFromMenu() {
        guard isActive else { return }
        guard !isScrollbackActive else { return }
        guard window?.firstResponder === pane.view else {
            return
        }

        // Capture the live terminal's current scroll position — the
        // scrollback view opens at this position. Clear any selection now
        // but defer scrolling the live view to bottom until after the
        // WKWebView is visible (avoids a flash of the live view jumping).
        let scrollPosition = pane.viewportRow
        pane.clearSelection()

        createScrollback(initialScrollLine: scrollPosition)
    }

    /// Cmd+F entry point. Routes to the existing overlay's find
    /// bar if the overlay is already open; otherwise opens a
    /// fresh overlay at the current viewport and queues find
    /// activation for after onReady fires. Same focus/active
    /// gates as enterScrollbackFromMenu so only the focused
    /// pane in the active session responds.
    private func activateFindOnScrollback() {
        // Gate the existing-overlay early-return on isActive too.
        // Otherwise a scrollback overlay alive in a non-active
        // session pane (or this pane while a different tab is
        // showing) eagerly grabs Cmd+F and binds the find-bar
        // panel to the wrong controller.
        guard isActive else { return }
        if let overlay = scrollbackOverlay {
            overlay.activateFind()
            return
        }
        guard window?.firstResponder === pane.view else { return }

        let scrollPosition = pane.viewportRow
        pane.clearSelection()

        pendingFindActivation = true
        createScrollback(initialScrollLine: scrollPosition)
    }

    /// Create the scrollback overlay with an HTML rendering of the live terminal's buffer.
    private func createScrollback(initialScrollLine: Int? = nil) {
        // The pane produces an opaque `ScrollbackSnapshot` —
        // chrome doesn't reach into SwiftTerm types to render.
        // The renderer iterates the snapshot's engine-agnostic
        // cell stream, so re-rendering on theme/font change is
        // just another `ScrollbackHTMLRenderer.render(snapshot:
        // ...)` invocation against the same frozen snapshot.
        guard let snapshot = pane.captureScrollbackSnapshot() else {
            return
        }
        self.currentSnapshot = snapshot

        // Use provided scroll position, or default to bottom of buffer
        let initialScrollLine = initialScrollLine ?? snapshot.yDisp

        // Get current font metrics for CSS matching
        let font = pane.font
        let cellHeight = pane.cellHeight
        let theme = TerminalColorTheme.theme(
            named: SettingsManager.shared.settings.terminalColorThemeName
        )

        // Render buffer to HTML
        let html = ScrollbackHTMLRenderer.render(
            snapshot: snapshot,
            theme: theme,
            fontFamily: font.fontName,
            fontSize: font.pointSize,
            cellHeight: cellHeight,
            textEntry: SettingsManager.shared.settings.textEntry.jsPayload
        )

        // Create web view with theme background for rubber-band overscroll
        let webView = ScrollbackWebView(
            frame: pane.view.bounds,
            html: html,
            initialScrollLine: initialScrollLine,
            backgroundColor: theme.backgroundColorValue
        )
        webView.onDismiss = { [weak self] in
            self?.dismissScrollback(reason: .dismissed)
        }
        webView.onReady = { [weak self] in
            // Scroll the live terminal to the bottom now that the scrollback
            // overlay is visible — prevents a flash of the live view jumping.
            guard let self = self else { return }
            self.pane.snapViewportToBottom()

            // Restore note cards if this is a reload (theme/font change)
            webView.restoreNoteState()

            // Push initial Send-button state and wire live
            // subscriptions. Initial push matters because
            // the overlay may open with a blocker already
            // in effect (e.g. shell scrollback opened while
            // the session is stopped).
            self.refreshSendButtonState()
            self.subscribeToSendButtonStateChanges()

            // Push initial focus state into the new
            // overlay. The KVO observer is already running
            // (view-lifetime, not scrollback-scoped), so
            // future first-responder changes flow through
            // automatically — but the overlay just spawned
            // and needs its starting tint set.
            self.refreshFocusState()

            // If scrollback was opened by Cmd+F, bring up the
            // find bar now that the overlay has finished
            // painting. Single-shot — flag is cleared so a
            // subsequent overlay open via menu/scroll-wheel
            // doesn't spuriously activate find.
            if self.pendingFindActivation {
                self.pendingFindActivation = false
                self.scrollbackOverlay?.activateFind()
            }
        }
        webView.onConfirmDismiss = { [weak self] in
            self?.showDismissConfirmation()
        }
        webView.onSendToClaude = { [weak self] message in
            guard let self = self else { return }
            guard let target = self.pane.sendToClaudeTarget,
                  target.disabledReason() == nil
            else { return }  // belt+suspenders — JS should disable the button

            // Record timeline event before dismiss destroys
            // the web view and its notes.
            if let lsid = self.pane.ledgerSessionId,
               let overlay = self.scrollbackOverlay {
                let notes = overlay.scrollbackView.notes
                let expandedNotes: [[String: Any]] = notes.map {
                    note in
                    [
                        "start_line": note.startLine,
                        "end_line": note.endLine,
                        "line_content": note.lineContent,
                        "note": note.content,
                    ] as [String: Any]
                }

                let detailData: [String: Any] = [
                    "pane": self.pane.paneKind,
                    "note_count": notes.count,
                    "message": message,
                    "notes": expandedNotes,
                ]

                TimelineService.recordViaStdin(
                    ledgerSessionId: lsid,
                    eventType: "scrollback:reviewed",
                    source: "galaxy-app/views/terminal",
                    detailData: detailData
                )
            }

            self.performScrollbackTeardown(reason: .reviewed)
            // The session owns the whole sequence — wait for the child to be
            // able to read, type, pace, submit. This used to write and pace and
            // submit here, which is how it came to hold its own copy of the
            // delay and to skip the readiness wait entirely.
            target.send(message)
        }
        webView.onConfirmDiscardForm = { [weak self] in
            self?.showDiscardNoteFormConfirmation()
        }
        webView.onConfirmDiscardEdit = { [weak self] in
            self?.showDiscardNoteEditConfirmation()
        }
        webView.onConfirmDragReplace = {
            [weak self] startLine, endLine in
            self?.showDragReplaceNoteConfirmation(
                startLine: startLine,
                endLine: endLine
            )
        }
        webView.onConfirmSendWithUnsavedComment = { [weak self] in
            self?.showSendWithUnsavedCommentConfirmation()
        }
        webView.onNoteChanged = {
            [weak self] action, detailData in
            guard let self = self,
                  let lsid = self.pane.ledgerSessionId
            else { return }
            var enriched = detailData
            enriched["pane"] = self.pane.paneKind
            TimelineService.record(
                ledgerSessionId: lsid,
                eventType:
                    "scrollback.note:\(action)",
                source:
                    "galaxy-app/views/scrollback",
                detailData: enriched
            )
        }

        // Create overlay container with border and pill. Sized to
        // paddedBounds() so the scrollback view aligns exactly
        // with the live terminal's position inside the padded
        // host — avoiding the up-left / down-right shift on
        // enter / exit that happened when the overlay was sized
        // to the full (unpadded) host bounds.
        //
        // The `isActiveSurface` predicate lets the overlay
        // self-gate whether it currently owns the shared find
        // panel. The combine subscriptions installed in
        // `setupCombineSubscriptions` call back into
        // `refreshFindBarPanelPresentation` so the overlay
        // re-evaluates on every tab / session switch.
        let overlay = ScrollbackOverlayView(
            frame: paddedBounds(),
            scrollbackView: webView,
            isActiveSurface: { [weak self] in
                guard let self = self,
                      let mySessionId = self.owningSession?.id
                else { return false }
                let manager = SessionManager.shared
                return manager.activeTab == .terminal
                    && manager.activeSessionId == mySessionId
            }
        )
        overlay.autoresizingMask = []

        // Add above drag highlight so it's the topmost interactive layer
        addSubview(overlay, positioned: .above, relativeTo: dragHighlightView)
        scrollbackOverlay = overlay

        // Publish scrollback-active state to the session model
        // so cross-pane consumers (shell pane's send-to-claude
        // gate) can subscribe via Combine instead of polling.
        // Only the session pane writes this signal — shell-pane
        // scrollbacks don't gate the cross-pane button.
        if pane is SessionTerminalPane,
           let session = self.session
        {
            session.setSessionPaneScrollbackActive(true)
        }

        // Generate duration ID and fire scrollback:entered event
        let durationId = "scrollback--\(UUID().uuidString)"
        scrollbackDurationId = durationId
        if let lsid = pane.ledgerSessionId {
            TimelineService.record(
                ledgerSessionId: lsid,
                eventType: "scrollback:entered",
                source: "galaxy-app/views/terminal",
                durationIdentifier: durationId,
                detailData: ["pane": pane.paneKind]
            )
        }

        // Make WKWebView first responder for keyboard events
        window?.makeFirstResponder(webView.webView)
    }

    /// Dismiss scrollback with a reason. When reason is `.dismissed`
    /// and unsaved notes exist, shows a confirmation dialog instead
    /// of tearing down immediately.
    private func dismissScrollback(reason: ScrollbackExitReason) {
        guard let overlay = scrollbackOverlay else { return }

        // Guard against losing unsaved notes — only for user-
        // initiated dismiss (not reviewed or sessionEnded).
        if reason == .dismissed
            && overlay.scrollbackView.hasNotes {
            showDismissConfirmation()
            return
        }

        performScrollbackTeardown(reason: reason)
    }

    /// Unconditional scrollback teardown. Fires the
    /// scrollback:exited timeline event, destroys the WKWebView,
    /// nils the overlay, and starts the re-entry cooldown.
    /// Idempotent — safe to call from multiple exit paths.
    private func performScrollbackTeardown(
        reason: ScrollbackExitReason
    ) {
        // Belt-and-suspenders: never let a stale
        // pendingFindActivation flag leak past the lifetime
        // of the overlay it was set for.
        pendingFindActivation = false

        guard let overlay = scrollbackOverlay else { return }

        // Close find before tearing anything down. The bar is
        // anchored to this overlay, and the first-responder
        // restore below should not race a panel that is about to
        // lose its web view. Synchronous, where the overlay's own
        // deinit safety net has to hop to the main actor.
        overlay.findController.isVisible = false

        // Fire scrollback:exited timeline event before teardown
        // destroys the overlay and its notes.
        if let lsid = pane.ledgerSessionId {
            let notes = overlay.scrollbackView.notes
            let durationId = scrollbackDurationId

            if reason == .reviewed {
                // Notes already captured in scrollback:reviewed
                TimelineService.record(
                    ledgerSessionId: lsid,
                    eventType: "scrollback:exited",
                    source: "galaxy-app/views/terminal",
                    durationIdentifier: durationId,
                    detailData: [
                        "pane": pane.paneKind,
                        "reason": reason.rawValue,
                        "note_count": notes.count,
                    ]
                )
            } else if notes.isEmpty {
                TimelineService.record(
                    ledgerSessionId: lsid,
                    eventType: "scrollback:exited",
                    source: "galaxy-app/views/terminal",
                    durationIdentifier: durationId,
                    detailData: [
                        "pane": pane.paneKind,
                        "reason": reason.rawValue,
                    ]
                )
            } else {
                // Capture discarded notes for recovery
                let expandedNotes: [[String: Any]] =
                    notes.map { note in
                        [
                            "start_line": note.startLine,
                            "end_line": note.endLine,
                            "line_content": note.lineContent,
                            "note": note.content,
                        ] as [String: Any]
                    }
                TimelineService.recordViaStdin(
                    ledgerSessionId: lsid,
                    eventType: "scrollback:exited",
                    source: "galaxy-app/views/terminal",
                    durationIdentifier: durationId,
                    detailData: [
                        "pane": pane.paneKind,
                        "reason": reason.rawValue,
                        "note_count": notes.count,
                        "discarded_notes": expandedNotes,
                    ]
                )
            }
        }

        // Restore first responder to live terminal only if the
        // WKWebView currently owns it — avoid stealing focus
        // from something else.
        if window?.firstResponder
            === overlay.scrollbackView.webView {
            window?.makeFirstResponder(pane.view)
        }

        // Clear Send-button state subscriptions before the
        // overlay goes away — the timer publisher would keep
        // firing and the button ID would be gone.
        sendButtonStateCancellables.removeAll()
        // Note: `firstResponderObservation` stays alive —
        // its lifetime is the host view's, since it also
        // drives the always-on pane dim.

        // Explicit teardown breaks the WKWebView retain cycle so
        // the web process is freed immediately rather than leaking.
        overlay.scrollbackView.teardown()
        overlay.removeFromSuperview()
        scrollbackOverlay = nil
        scrollbackDurationId = nil
        currentSnapshot = nil

        // Mirror the createScrollback path: clear the
        // session-model scrollback flag for session-pane
        // overlays so cross-pane consumers see the change.
        if pane is SessionTerminalPane,
           let session = self.session
        {
            session.setSessionPaneScrollbackActive(false)
        }

        // Start cooldown to prevent trackpad momentum from
        // re-creating scrollback
        if SettingsManager.shared.settings
            .scrollToEnterScrollback {
            startScrollbackCooldown()
        }
    }

    /// Push the current `sendToClaudeTarget.disabledReason()`
    /// into the scrollback overlay's JS via
    /// `ScrollbackManager.setSendButtonState`. Safe to call
    /// when the overlay isn't open — bails early. String
    /// escaping handles apostrophes in reason text (e.g.
    /// "Don't…") and literal backslashes defensively, so the
    /// inline JS template never breaks on user-facing
    /// wording changes.
    private func refreshSendButtonState() {
        guard let overlay = scrollbackOverlay else { return }
        let target = pane.sendToClaudeTarget
        let reason = target?.disabledReason()
        let enabled = (target != nil && reason == nil)
        let tooltip = reason ?? ""
        let escaped = tooltip
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js =
            "ScrollbackManager.setSendButtonState(" +
            "\(enabled), '\(escaped)')"
        overlay.scrollbackView.webView
            .evaluateJavaScript(js)
    }

    /// Wire the push inputs that make the Send-button state
    /// react live to blocker changes. Called from
    /// `createScrollback` after the web view is ready;
    /// cleared in `performScrollbackTeardown`.
    ///
    /// - Shell pane has two blockers: the owning session's
    ///   running state and the session pane's scrollback
    ///   overlay state. Both are now push-based via
    ///   `@Published` properties on the Session model.
    /// - Session pane has one blocker (its own running
    ///   state), push-based. Future Session-pane blockers
    ///   can reuse this same subscription path.
    private func subscribeToSendButtonStateChanges() {
        sendButtonStateCancellables.removeAll()

        if let shell = pane as? ShellTerminalPane,
           let session = shell.session {
            Publishers.CombineLatest(
                session.$isRunning,
                session.$hasExited
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshSendButtonState()
            }
            .store(in: &sendButtonStateCancellables)

            // Push: session pane's scrollback overlay state.
            // Subscription target is the durable Session model,
            // which survives the stop/resume cycles that
            // destroy and recreate the session pane's
            // TerminalHostView.
            session.$sessionPaneScrollbackActive
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshSendButtonState()
                }
                .store(in: &sendButtonStateCancellables)
        }

        if let sessionPane = pane as? SessionTerminalPane,
           let session = sessionPane.session {
            Publishers.CombineLatest(
                session.$isRunning,
                session.$hasExited
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshSendButtonState()
            }
            .store(in: &sendButtonStateCancellables)
        }
    }

    /// (Re)bind the KVO observer for the focus-driven
    /// dim. Idempotent — invalidates the prior observation
    /// before binding to the current window. When this
    /// view is removed from a window, the resulting nil
    /// window simply leaves the observer torn down until
    /// we're attached again.
    private func startObservingFirstResponder() {
        firstResponderObservation?.invalidate()
        firstResponderObservation = nil
        guard let window = window else { return }
        firstResponderObservation = window.observe(
            \.firstResponder, options: [.initial, .new]
        ) { [weak self] _, _ in
            self?.refreshFocusState()
        }
    }

    /// Apply the current focus state to both signals
    /// gated on it: the live terminal pane's `alphaValue`
    /// and (if a scrollback is open) the overlay's pill +
    /// border tint. "Focused" = first-responder is this
    /// host view or any descendant — which covers the
    /// SwiftTerm view, the scrollback web view, and any
    /// nested first-responder we haven't thought of.
    private func refreshFocusState() {
        let fr = window?.firstResponder
        var isFocusInPane = false
        if let frView = fr as? NSView {
            isFocusInPane = (frView === self)
                || frView.isDescendant(of: self)
        }

        // Record this pane as the session's last-focused
        // when focus enters our subtree. Drives tab-switch /
        // session-switch / app-becomes-key restoration so
        // the user returns to the pane they were typing in.
        // Only writes on entry — leaving (e.g., to a rename
        // text field) keeps the prior value so post-edit
        // restoration lands back where they were.
        if isFocusInPane {
            let myKind: Session.ScrollbackPaneKind =
                pane is ShellTerminalPane ? .shell : .session
            if owningSession?.lastFocusedPaneKind != myKind {
                owningSession?.lastFocusedPaneKind = myKind
            }
        }

        // Pane-level dim: animate alpha so the transition
        // doesn't feel snappy/jarring on every focus
        // shift. 150ms ease matches NSWindow's own
        // active/inactive cadence.
        let target: CGFloat = isFocusInPane
            ? 1.0
            : Self.unfocusedPaneAlpha
        if pane.view.alphaValue != target {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                pane.view.animator().alphaValue = target
            }
        }

        // Scrollback overlay dim — same focus signal
        // gates the pill + border alpha on the overlay
        // when one is open.
        scrollbackOverlay?.isPaneFocused = isFocusInPane
    }

    /// Show an NSAlert sheet asking the user to confirm discarding notes.
    private func showDismissConfirmation() {
        guard let overlay = scrollbackOverlay,
              let window = window else { return }
        let noteCount = overlay.scrollbackView.notes.count

        SheetAlert.confirm(
            in: window,
            message: "Discard scrollback notes?",
            detail: "You have \(noteCount) unsaved "
                + "note\(noteCount == 1 ? "" : "s"). "
                + "They will be lost if you exit scrollback.",
            onConfirm: { [weak self] in
                self?.performScrollbackTeardown(
                    reason: .dismissed
                )
            },
            onCancel: { [weak self] in
                self?.requestFocus()
            }
        )
    }

    /// Query the scrollback JS for unsaved work (submitted notes,
    /// form content, or in-progress edits). Completes with false
    /// if scrollback isn't active.
    private func checkScrollbackUnsavedWork(
        completion: @escaping (Bool) -> Void
    ) {
        guard let overlay = scrollbackOverlay else {
            completion(false)
            return
        }

        overlay.scrollbackView.webView.evaluateJavaScript(
            "ScrollbackManager.notes.hasUnsavedWork()"
        ) { result, _ in
            let hasWork = result as? Bool ?? false
            DispatchQueue.main.async {
                completion(hasWork)
            }
        }
    }

    /// Show an NSAlert asking to discard new note form content.
    private func showDiscardNoteFormConfirmation() {
        guard let overlay = scrollbackOverlay,
              let window = window else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard note?",
            detail: "You have unsaved text in the note form. "
                + "It will be lost if you dismiss.",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.forceDiscardForm()"
                )
            },
            onCancel: { [weak self] in
                self?.requestFocus()
            }
        )
    }

    /// Show an NSAlert warning that sending will drop unsaved
    /// comment text (an open note form or in-progress edit).
    /// On confirm: force the send past the JS guard, which
    /// discards the open comment as teardown destroys the web
    /// view. On cancel: return focus so the user can finish it.
    private func showSendWithUnsavedCommentConfirmation() {
        guard let overlay = scrollbackOverlay,
              let window = window else { return }

        SheetAlert.confirm(
            in: window,
            message: "Send without unsaved comment?",
            detail: "You have unsaved text in a comment that "
                + "won't be included. It will be lost if you send.",
            confirm: "Send",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.sendToClaude(true)"
                )
            },
            onCancel: { [weak self] in
                self?.requestFocus()
            }
        )
    }

    /// Show an NSAlert asking to discard edit changes to a note.
    private func showDiscardNoteEditConfirmation() {
        guard let overlay = scrollbackOverlay,
              let window = window else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard changes?",
            detail: "You have unsaved changes to this note. "
                + "They will be lost if you cancel editing.",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.forceDiscardEdit()"
                )
            },
            onCancel: { [weak self] in
                self?.requestFocus()
            }
        )
    }

    /// Show an NSAlert asking to discard unsaved note form content
    /// before opening a new form at a different drag selection.
    private func showDragReplaceNoteConfirmation(
        startLine: Int,
        endLine: Int
    ) {
        guard let overlay = scrollbackOverlay,
              let window = window else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard note?",
            detail: "You have unsaved text in the note form. "
                + "It will be lost if you select different "
                + "lines.",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes"
                    + ".showSelectionToolbar("
                    + "\(startLine), \(endLine))"
                )
            },
            onCancel: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.focusForm()"
                )
            }
        )
    }

    /// Apply current font/theme settings to the scrollback view if present.
    /// Rebuilds the entire HTML document with the new theme/font, preserving
    /// the current scroll position. Theme changes require a full rebuild
    /// because inline <span> styles are baked from the original theme.
    private func applySettingsToScrollback() {
        guard let overlay = scrollbackOverlay else { return }
        guard let snapshot = currentSnapshot else { return }

        // Save current scroll position before rebuilding
        overlay.scrollbackView.webView.evaluateJavaScript(
            "ScrollbackManager.getVisibleLine()"
        ) { [weak self] result, _ in
            guard let self = self else { return }
            _ = self  // keep self alive for the duration of the closure
            let scrollLine = result as? Int ?? 0

            let theme = TerminalColorTheme.theme(
                named: SettingsManager.shared.settings.terminalColorThemeName
            )
            let family = SettingsManager.shared.settings.terminalFontFamily
            let size = self.pane.fontSize

            // Compute font and cell height (same logic as Session)
            let font: NSFont
            if family == "SF Mono" {
                font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
            } else {
                font = NSFont(name: family, size: size)
                    ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            let ctFont = font as CTFont
            let cellHeight = ceil(
                CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont)
                    + CTFontGetLeading(ctFont)
            )

            let html = ScrollbackHTMLRenderer.render(
                snapshot: snapshot,
                theme: theme,
                fontFamily: font.fontName,
                fontSize: size,
                cellHeight: cellHeight,
                textEntry: SettingsManager.shared.settings.textEntry.jsPayload
            )

            overlay.scrollbackView.reload(html: html, scrollToLine: scrollLine)
        }
    }

    // MARK: - Terminal Text Injection

    /// Send text to the terminal, routing through the pane so
    /// bracketed-paste-mode handling stays inside the backend
    /// rather than the chrome layer.
    private func sendTextToTerminal(_ text: String, asPaste: Bool) {
        pane.send(text: text, asPaste: asPaste)
    }
}

// MARK: - Drag Highlight Overlay View

/// Transparent overlay view that draws a highlight border when files are dragged over
class DragHighlightView: NSView {
    var isHighlighted = false {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Critical: allow mouse events to pass through to terminal underneath
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard isHighlighted else { return }

        // Draw border highlight with enough inset for clean corners
        // 1px border needs 0.5px inset from edge to render fully inside bounds
        // Plus a little extra margin so corners don't clip against parent edges
        let borderRect = bounds.insetBy(dx: 2, dy: 2)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: 3, yRadius: 3)
        borderPath.lineWidth = 1

        // Use system accent color
        NSColor.controlAccentColor.setStroke()
        borderPath.stroke()
    }

    // Allow mouse events to pass through to the terminal view underneath
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
