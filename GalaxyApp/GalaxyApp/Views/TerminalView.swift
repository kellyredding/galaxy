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

    /// Where the host's terminal events are recorded.
    ///
    /// Supplied by the app rather than reached for, so the host describes what
    /// happened without knowing what stores it — and so an app with nothing to
    /// store into supplies nil and the describing stays put.
    let timelineRecorder: TerminalTimelineRecorder?

    /// Where the host reads configuration, and hears that it changed.
    ///
    /// Supplied for the same reason as the recorder: the settings store is one
    /// of the names a shared host cannot carry, and a behaviour the app turns
    /// off is a value read through here rather than code that is absent.
    let settings: GalacticConfigurationSource

    /// Told each time the user asks to find, however this app carries that.
    ///
    /// The host answers ⌘F but does not own the gesture — a menu does, and how
    /// a menu reaches the right surface is this app's business, not the
    /// terminal's.
    let findActivations: FindActivations

    /// How an interrupted turn gets recorded, or nil for a surface where turns
    /// do not happen — the shell pane beside an agent being exactly that.
    let turnInterrupt: TurnInterrupt?

    /// Whether this pane belongs to the session the user selected. Drives
    /// hiding and drag registration — the questions that really are about
    /// which session owns the pane.
    let isActiveSession: Bool

    /// Whether this pane is the surface the user is actually looking at:
    /// the selected session *and* the terminal tab. Drives focus, scrollback
    /// entry and find.
    ///
    /// Separate from `isActiveSession` because the terminal tab stays mounted
    /// when another tab is showing — it is switched by opacity, not by being
    /// torn down. A pane that reads only the session believes it is in front
    /// of the user while a reader is showing, and takes the caret back from
    /// whatever the user was typing in.
    let isVisibleSurface: Bool

    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(
            pane: pane,
            timelineRecorder: timelineRecorder,
            settings: settings,
            findActivations: findActivations,
            turnInterrupt: turnInterrupt
        )
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        let wasVisible = nsView.isVisibleSurface
        let sessionChanged = nsView.isActiveSession != isActiveSession

        // didSet on isActiveSession runs updateDragRegistration when
        // the value flips (guarded by != oldValue). Only call
        // refreshDragRegistration explicitly when the session flag
        // didn't flip — that's the case where
        // pane.acceptsFileDrops may have changed and the
        // didSet path skipped. Avoids paying for two
        // register/unregister cycles per transition row.
        nsView.isActiveSession = isActiveSession
        nsView.isVisibleSurface = isVisibleSurface
        if !sessionChanged {
            nsView.refreshDragRegistration()
        }

        if !isActiveSession {
            nsView.resignFocusIfHeld()
        }

        // Skip the write when the value already matches —
        // NSView.setHidden does KVO + layer-dirty work even
        // on no-op assignments. After SwiftUI's per-row
        // short-circuit, only the two transition rows
        // actually need this poke.
        let shouldHide = !isActiveSession
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
        if isVisibleSurface && !wasVisible {
            nsView.requestFocusIfPreferred()
        }
    }
}

extension FocusableTerminalView: Equatable {
    /// Identity equality: same pane (by reference) and same
    /// activity flags. Used via `.equatable()` at call sites
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
        lhs.isActiveSession == rhs.isActiveSession
            && lhs.isVisibleSurface == rhs.isVisibleSurface
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

    /// The pane registry this host coordinates through, resolved through the
    /// pane exactly as the session itself is.
    ///
    /// Reached as the contract rather than as this app's type, and per session
    /// rather than from a static: the answers it holds are one session's, so a
    /// shared answer would attribute a note to whichever session was asked
    /// about last. Nil when the pane has no session, which is the same window
    /// in which nothing else here has one either.
    private var paneRegistry: (any TerminalPaneRegistry)? {
        owningSession?.paneRegistry
    }

    /// Where this host's terminal events go, or nil to record nothing.
    private let timelineRecorder: TerminalTimelineRecorder?

    /// Where this host reads configuration, and hears that it changed.
    private let settings: GalacticConfigurationSource

    /// Told each time the user asks to find within this surface.
    private let findActivations: FindActivations

    /// How an interrupted turn gets recorded, or nil where turns do not happen.
    private let turnInterrupt: TurnInterrupt?

    /// Which pane this host is showing, as the pane itself reports it.
    private var paneKind: TerminalPaneKind { pane.paneKind }

    /// Is this pane's session the selected one? Controls drag-drop
    /// registration and hiding.
    var isActiveSession: Bool = false {
        didSet {
            if isActiveSession != oldValue {
                updateDragRegistration()
            }
        }
    }

    /// Is this pane the surface in front of the user — selected session and
    /// terminal tab both? Supplied by the representable; see its declaration
    /// for why this is not the same question as `isActiveSession`.
    var isVisibleSurface: Bool = false {
        didSet {
            guard oldValue != isVisibleSurface else { return }
            // An open overlay holds the shared find panel only while its
            // surface is the one in front of the user, and it is an NSView deep
            // in the hierarchy with no way to learn that it no longer is. The
            // host is the only thing that knows, and this is the moment it
            // finds out. Left unsaid, the panel stays up over whatever the user
            // moved to, bound to a surface that is no longer showing.
            scrollbackOverlay?.refreshFindBarPanelPresentation()
        }
    }
    private var didSetUp = false

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

    /// Whether a scroll-up opens the scrollback overlay, and the post-dismiss
    /// cooldown that stops the tail of the dismissing gesture from re-opening
    /// it. Both answers come from configuration, so the whole behaviour is one
    /// value away from off.
    private let scrollEntry = ScrollToEnterScrollback()

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

    init(
        pane: TerminalPane,
        timelineRecorder: TerminalTimelineRecorder?,
        settings: GalacticConfigurationSource,
        findActivations: FindActivations,
        turnInterrupt: TurnInterrupt?
    ) {
        self.pane = pane
        self.timelineRecorder = timelineRecorder
        self.settings = settings
        self.findActivations = findActivations
        self.turnInterrupt = turnInterrupt
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
        firstResponderObservation?.invalidate()
        let key = ObjectIdentifier(self)
        paneRegistry?.unregisterUnsavedWorkChecker(key)
        paneRegistry?.unregisterFocusRestorer(key)
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

            // A bare Esc during a turn is the user stopping it, which is worth
            // recording. Deliberately not consumed here or below: Esc still has
            // to reach the terminal, since aborting the stream is Claude Code's
            // own job on the far end.
            self.turnInterrupt.recordIfInterrupting(event)

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
        if isActiveSession && pane.acceptsFileDrops {
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

        if !didSetUp && window != nil {
            setupTerminal()
            didSetUp = true
        }

        // Re-bind the first-responder observer to the
        // current window. Handles both add (window
        // assigned) and remove (window goes nil), so the
        // observer only exists while we're actually in a
        // window and can never leak across reattachment.
        startObservingFirstResponder()
    }

    private func setupTerminal() {
        mountTerminalSurface()
        observeScrollUp()
        observeFontSize()
        registerWithPaneRegistry()
        observeSessionExit()
        observeSettingsChanges()
        observeAppTermination()
        observeScrollbackNotification()
        observeFindActivation()
        observeWindowBecameKey()
        observeKeyWindowChanges()

        // Request focus after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.requestFocus()
        }
    }

    /// Paint the host strip, mount the terminal inside its inset container,
    /// and lay the drag highlight over the top.
    private func mountTerminalSurface() {
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

        // Add drag highlight overlay ON TOP of the terminal
        // container (the terminal is nested inside it, so the
        // highlight orders against the container, its host sibling).
        let highlight = DragHighlightView(frame: bounds)
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight, positioned: .above, relativeTo: terminalContainer)
        dragHighlightView = highlight
    }

    private func observeScrollUp() {
        // Scroll-up interception — pane-generic. Both session
        // and shell panes route scroll-up through the pane
        // protocol so we enter scrollback mode uniformly.
        pane.onScrollUp = { [weak self] event in
            self?.handleScrollUp(event: event) ?? false
        }
    }

    private func observeFontSize() {
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
    }

    /// Register this host's scrollback-unsaved-work checker and pane-focus
    /// restorer on the pane registry, each tagged with its pane kind so
    /// callers can filter to the panes whose loss matters in their context.
    /// Paired with the unregister in `deinit`.
    private func registerWithPaneRegistry() {
        if let registry = paneRegistry {
            let kind = paneKind
            let key = ObjectIdentifier(self)
            registry.registerUnsavedWorkChecker(
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
            registry.registerFocusRestorer(
                key, kind: kind
            ) { [weak self] in
                self?.requestFocus()
            }
        }
    }

    private func observeSessionExit() {
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
    }

    private func observeSettingsChanges() {
        // Font family changes — re-render an open scrollback so it keeps
        // matching the live terminal underneath it.
        //
        // The prepend/dropFirst pair seeds a baseline for the dedupe rather
        // than replaying a value: the source deliberately does not resend the
        // current configuration, so with nothing to compare against, the first
        // change of any kind would read as a font change and re-render for
        // nothing. No `receive(on:)` — the source guarantees main.
        settings.configurationChanges
            .map { $0.terminalFontFamily }
            .prepend(settings.configuration.terminalFontFamily)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.applySettingsToScrollback()
            }
            .store(in: &cancellables)

        // Color theme changes — repaint the padded host strip so it tracks the
        // theme, and re-render any open scrollback. Same baseline treatment.
        settings.configurationChanges
            .map { $0.terminalColorThemeName }
            .prepend(settings.configuration.terminalColorThemeName)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyHostBackgroundColor()
                self?.applySettingsToScrollback()
            }
            .store(in: &cancellables)
    }

    private func observeAppTermination() {
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
    }

    private func observeScrollbackNotification() {
        // Observe Cmd+S menu action for scrollback entry
        NotificationCenter.default.publisher(for: .enterScrollback)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.enterScrollbackFromMenu()
            }
            .store(in: &cancellables)
    }

    private func observeFindActivation() {
        // If a scrollback is already open here, bring up its find bar;
        // otherwise open one at the current viewport and queue the bar for
        // after the page paints.
        findActivations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.activateFindOnScrollback()
            }
            .store(in: &cancellables)
    }

    private func observeWindowBecameKey() {
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
                guard self.isVisibleSurface else { return }
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
                guard self.isPreferredPane else { return }
                if window.firstResponder !== self.pane.view {
                    self.requestFocus()
                }
            }
            .store(in: &cancellables)
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
        TerminalHostBackground.apply(
            to: self,
            themeNamed: settings.configuration.terminalColorThemeName
        )
    }

    /// Re-evaluate the focus dim whenever any window takes or gives up key.
    ///
    /// The find bar lives in its own panel, so it taking key moves focus out
    /// of this view without changing any first responder here — the KVO that
    /// normally drives the dim sees nothing at all. Deliberately unfiltered by
    /// window: the panel is not this view's window, and which window is
    /// involved is precisely what must not be assumed.
    private func observeKeyWindowChanges() {
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshFocusState() }
                .store(in: &cancellables)
        }
    }

    /// Whether this pane is the one the session remembers the user typing in.
    ///
    /// The gate that keeps two panes of one session from both answering a
    /// command meant for whichever the user was actually in.
    private var isPreferredPane: Bool {
        (paneRegistry?.lastFocusedPaneKind ?? .session) == paneKind
    }

    /// Give up first responder if this host holds it, and close the find bar.
    ///
    /// Called as this session stops being the selected one, which is also when
    /// the pane gets hidden — and the order matters enough that the reason is
    /// recorded on the shared implementation.
    func resignFocusIfHeld() {
        TerminalFocus.resignIfHeld(
            in: window,
            host: self,
            paneView: pane.view,
            findController: scrollbackOverlay?.findController
        )
    }

    func requestFocus() {
        TerminalFocus.request(
            in: window,
            isVisibleSurface: isVisibleSurface,
            resolveTarget: { [weak self] in
                guard let self else { return nil }
                // With a scrollback open, focus belongs to the overlay's web
                // view rather than the live terminal behind it — otherwise
                // scrollback is visible but keyboard-dead, and Esc has
                // nowhere to go.
                if let webView =
                    self.scrollbackOverlay?.scrollbackView.webView
                {
                    return TerminalFocusTarget(
                        responder: webView, isLivePane: false
                    )
                }
                return TerminalFocusTarget(
                    responder: self.pane.view, isLivePane: true
                )
            },
            onFocusedLivePane: { [weak self] in
                // Friendly re-pin on focus gain: if the user intends to follow
                // the live tail, snap back to the bottom. A no-op when already
                // pinned, and never reached while parked in scrollback.
                self?.pane.reassertFollowIfIntended()
            }
        )
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
        guard isPreferredPane else { return }
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
        return isActiveSession && pane.acceptsFileDrops
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
        var uniqueURLs: [URL] = []
        for url in urls {
            let path = url.standardized.path
            if !seenPaths.contains(path) {
                seenPaths.insert(path)
                uniqueURLs.append(url)
            }
        }

        // Send raw paths (like Cmd+V paste) so Claude Code shows gray box treatment
        let pathsText = uniqueURLs.map { $0.path }.joined(separator: " ") + " "

        // Bracketed paste, no submit — the user reads the paths back and
        // presses Return themselves. Straight to the pane: routing it through
        // the chrome added a name and decided nothing.
        pane.send(text: pathsText, asPaste: true)

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
        guard scrollEntry.shouldEnter(
            configuration: settings.configuration,
            isSurfaceOpen: isScrollbackActive,
            hasContent: pane.hasScrollbackContent
        ) else { return false }

        let scrollPosition = pane.viewportRow
        pane.clearSelection()
        createScrollback(initialScrollLine: scrollPosition)
        return true
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
        guard isVisibleSurface else { return }
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
        // Gate the existing-overlay early-return on visibility.
        // Otherwise a scrollback overlay alive in a non-active
        // session pane (or this pane while a different tab is
        // showing) eagerly grabs Cmd+F and binds the find-bar
        // panel to the wrong controller.
        //
        // The tab half of that used to be enforced only by whatever routed the
        // gesture here, while this comment claimed it — the predicate now says
        // what the comment always meant, and says it where a host that gets
        // its gestures from somewhere else still gets the guarantee.
        guard isVisibleSurface else { return }
        // Which pane answers is decided by focus memory rather than first
        // responder, because once the find panel takes key no pane holds
        // first responder at all — so a second press would reach nobody, and
        // with a split open both panes would otherwise answer the first.
        guard isPreferredPane else { return }
        if let overlay = scrollbackOverlay {
            overlay.activateFind()
            return
        }
        // Opening a fresh scrollback is the one path that does want the
        // terminal focused, so a background pane cannot spawn one.
        guard window?.firstResponder === pane.view else { return }

        let scrollPosition = pane.viewportRow
        pane.clearSelection()

        pendingFindActivation = true
        createScrollback(initialScrollLine: scrollPosition)
    }

    /// Create the scrollback overlay with an HTML rendering of the live terminal's buffer.
    private func createScrollback(initialScrollLine: Int? = nil) {
        // The pane produces an opaque snapshot — chrome never reaches into
        // engine types to render it, which is what lets the same frozen buffer
        // be rendered again on a theme or font change.
        let configuration = settings.configuration
        guard let opened = ScrollbackFactory.open(
            pane: pane,
            theme: TerminalColorTheme.theme(
                named: configuration.terminalColorThemeName
            ),
            textEntry: configuration.textEntry.jsPayload,
            initialScrollLine: initialScrollLine
        ) else { return }

        self.currentSnapshot = opened.snapshot
        let webView = opened.webView

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
                    "pane": self.paneKind.rawValue,
                    "note_count": notes.count,
                    "message": message,
                    "notes": expandedNotes,
                ]

                self.timelineRecorder.record(
                    sessionID: self.pane.ledgerSessionId
                ) { id in
                    TerminalTimelineEvent(
                        sessionID: id,
                        type: "scrollback:reviewed",
                        paneKind: self.paneKind,
                        source: "galaxy-app/views/terminal",
                        detail: detailData,
                        detailMayBeLarge: true
                    )
                }
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
            self.timelineRecorder.record(sessionID: lsid) { id in
                TerminalTimelineEvent(
                    sessionID: id,
                    type: "scrollback.note:\(action)",
                    paneKind: self.paneKind,
                    source: "galaxy-app/views/scrollback",
                    detail: detailData
                )
            }
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
            // The same question the host asks itself, asked once. This
            // expression used to be the only place the two halves were
            // combined correctly, while the host read the session half alone.
            isActiveSurface: { [weak self] in
                self?.isVisibleSurface ?? false
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
            paneRegistry?.setSessionPaneScrollbackActive(true)
        }

        // Generate duration ID and fire scrollback:entered event
        let durationId = "scrollback--\(UUID().uuidString)"
        scrollbackDurationId = durationId
        timelineRecorder.record(sessionID: pane.ledgerSessionId) { id in
            TerminalTimelineEvent(
                sessionID: id,
                type: "scrollback:entered",
                paneKind: paneKind,
                source: "galaxy-app/views/terminal",
                durationIdentifier: durationId
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
        timelineRecorder.record(sessionID: pane.ledgerSessionId) { id in
            let notes = overlay.scrollbackView.notes

            // Three shapes of the same event. A review already recorded its
            // notes in full, so this one only counts them; an exit with nothing
            // written has nothing to count; an exit that discards notes carries
            // them so they can be recovered, which is what makes its payload
            // unbounded.
            var detail: [String: Any] = ["reason": reason.rawValue]
            var mayBeLarge = false
            if reason == .reviewed {
                detail["note_count"] = notes.count
            } else if !notes.isEmpty {
                detail["note_count"] = notes.count
                detail["discarded_notes"] = notes.map { note in
                    [
                        "start_line": note.startLine,
                        "end_line": note.endLine,
                        "line_content": note.lineContent,
                        "note": note.content,
                    ] as [String: Any]
                }
                mayBeLarge = true
            }

            return TerminalTimelineEvent(
                sessionID: id,
                type: "scrollback:exited",
                paneKind: paneKind,
                source: "galaxy-app/views/terminal",
                durationIdentifier: scrollbackDurationId,
                detail: detail,
                detailMayBeLarge: mayBeLarge
            )
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
            paneRegistry?.setSessionPaneScrollbackActive(false)
        }

        // Ignore the tail of the gesture that dismissed this, or it re-opens
        // what the user just closed.
        scrollEntry.beginCooldown(configuration: settings.configuration)
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
            // Subscription target is the registry the durable
            // Session model owns, which likewise survives the
            // stop/resume cycles that destroy and recreate the
            // session pane's TerminalHostView.
            session.paneRegistry.sessionPaneScrollbackActivePublisher
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
        if isFocusInPane, paneRegistry?.lastFocusedPaneKind != paneKind {
            paneRegistry?.lastFocusedPaneKind = paneKind
        }

        // The find bar is this pane's own UI even though AppKit puts it in a
        // separate window, so searching a scrollback must not read as having
        // left the pane — otherwise the pane dims and its overlay tints down
        // while the user is looking straight at it. Asserted rather than
        // inferred from first responder: which window holds focus while a
        // child panel is key is AppKit's business, and this does not need to
        // depend on getting that right.
        //
        // Gated on the bar actually holding key, not merely being open, so
        // that clicking into the sibling pane still dims this one.
        if !isFocusInPane,
           let findController = scrollbackOverlay?.findController,
           FindBarPanelController.shared.isKeyWindow(for: findController) {
            isFocusInPane = true
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

    private func showDismissConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        overlay.confirmDiscardNotes(
            in: window,
            onDiscard: { [weak self] in
                self?.performScrollbackTeardown(reason: .dismissed)
            },
            onCancel: { [weak self] in self?.requestFocus() }
        )
    }

    private func showDiscardNoteFormConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        overlay.confirmDiscardNoteForm(in: window) { [weak self] in
            self?.requestFocus()
        }
    }

    private func showSendWithUnsavedCommentConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        overlay.confirmSendWithUnsavedComment(in: window) { [weak self] in
            self?.requestFocus()
        }
    }

    private func showDiscardNoteEditConfirmation() {
        guard let overlay = scrollbackOverlay, let window else { return }
        overlay.confirmDiscardNoteEdit(in: window) { [weak self] in
            self?.requestFocus()
        }
    }

    private func showDragReplaceNoteConfirmation(
        startLine: Int,
        endLine: Int
    ) {
        guard let overlay = scrollbackOverlay, let window else { return }
        overlay.confirmReplaceSelection(
            in: window, startLine: startLine, endLine: endLine
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

    /// Apply current font/theme settings to the scrollback view if present.
    /// Rebuilds the entire HTML document with the new theme/font, preserving
    /// the current scroll position. Theme changes require a full rebuild
    /// because inline <span> styles are baked from the original theme.
    private func applySettingsToScrollback() {
        guard let overlay = scrollbackOverlay,
              let snapshot = currentSnapshot else { return }
        let configuration = settings.configuration
        overlay.reRender(
            snapshot: snapshot,
            theme: TerminalColorTheme.theme(
                named: configuration.terminalColorThemeName
            ),
            // The font the surface is actually showing, not the family that was
            // asked for. They differ whenever the configured family does not
            // resolve and the pane fell back, and rendering the snapshot in a
            // font the terminal is not using is visible as a seam at the
            // boundary between the two.
            fontFamily: pane.font.fontName,
            fontSize: pane.fontSize,
            textEntry: configuration.textEntry.jsPayload
        )
    }

}

// MARK: - Drag Highlight Overlay View

