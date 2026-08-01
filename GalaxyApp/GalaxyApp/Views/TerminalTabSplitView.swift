import AppKit
import Combine
import SwiftUI
import Galactic

/// Split container for the Terminal tab, per Claude session.
/// Top: `SessionPaneView` (always). Bottom: optional
/// `ShellPaneView` when a shell is open.
///
/// One instance per `Session` in
/// `TerminalContainerView`'s ZStack, so split state
/// (ratio, shell open/closed, shell pane instance) is
/// per-session and not persisted across app restarts.
struct TerminalTabSplitView: View {
    @ObservedObject var session: Session
    let isActiveSession: Bool
    let isVisibleSurface: Bool
    let onResume: () -> Void

    @StateObject private var state = SplitState()

    /// How far the divider may travel. The shared window, so the drag and the
    /// configurable default cannot disagree about it — and so a change to it is
    /// made once.
    private static let bounds = PaneSplitBounds.standard

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let topHeight = clampedTopHeight(
                totalHeight: totalHeight
            )

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    SessionPaneView(
                        session: session,
                        isActiveSession: isActiveSession,
                        isVisibleSurface: isVisibleSurface,
                        onResume: onResume
                    )
                    .frame(
                        height: state.shellPane == nil
                            ? totalHeight
                            : topHeight
                    )

                    if let shellPane = state.shellPane {
                        ShellPaneView(
                            pane: shellPane,
                            isActiveSession: isActiveSession,
                            isVisibleSurface: isVisibleSurface,
                            onBarDragBegan: {
                                state.split.beginDrag()
                            },
                            onBarDrag: { delta in
                                state.split.updateDrag(
                                    cursorDeltaY: delta,
                                    totalHeight: totalHeight,
                                    bounds: Self.bounds
                                )
                            },
                            onBarDragEnded: {
                                state.split.commitDrag()
                            },
                            onBarDoubleClick: {
                                withAnimation(
                                    .easeInOut(duration: 0.15)
                                ) {
                                    state.split.ratio =
                                        Self.configuredTopRatio()
                                }
                            }
                        )
                        .frame(height: totalHeight - topHeight)
                    }
                }

                // Ghost line indicator — shown only while the
                // user is actively dragging. Live-updating as
                // the cursor moves, without reflowing either
                // pane's terminal buffer until drag ends.
                if let preview = state.split.previewRatio,
                   state.shellPane != nil {
                    DragPreviewLineView(
                        shellPercentage: Int(
                            ((1.0 - preview) * 100)
                                .rounded()
                        )
                    )
                    .frame(height: 1)
                    .offset(y: totalHeight * preview)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .onReceive(
            TerminalTabCommands.shared.openShell
        ) { sessionId in
            guard sessionId == session.id else { return }
            if state.shellPane != nil {
                // Through the pane-focus registry, not the pane:
                // with a scrollback open on the shell, focusing
                // the pane lands on the live terminal hidden
                // behind the overlay, leaving it visible but
                // keyboard-dead with Esc going to the shell as
                // input.
                session.paneRegistry.restoreFocus(kind: .shell)
            } else {
                state.openShell(for: session)
            }
        }
        .onReceive(
            TerminalTabCommands.shared.focusSession
        ) { sessionId in
            guard sessionId == session.id else { return }
            // Same reason as the shell above: reaching for the
            // backend skips the host that knows whether a
            // scrollback overlay is covering it.
            session.paneRegistry.restoreFocus(kind: .session)
        }
        .onReceive(
            TerminalTabCommands.shared.closeFocusedShell
        ) { sessionId in
            guard sessionId == session.id,
                  let pane = state.shellPane else { return }
            // Mirror session-pane Cmd+W: gate destructive
            // close on a confirmation sheet when scrollback
            // notes would be lost. The helper no-ops the
            // sheet when there's no unsaved work.
            SessionManager.shared.confirmAndCloseShellPane(
                session: session
            ) {
                pane.requestClose()
            }
        }
    }

    private func clampedTopHeight(
        totalHeight: CGFloat
    ) -> CGFloat {
        return totalHeight * state.split.clamped(to: Self.bounds)
    }

    /// Top-pane fraction derived from the user's configured
    /// default shell height. Clamped against the same drag
    /// window the view enforces so the setting can never
    /// disagree with live drag bounds. Used on shell open
    /// and on double-click reset.
    static func configuredTopRatio() -> CGFloat {
        PaneSplitRatio.topRatio(
            forBottomRatio: SettingsManager.shared.settings
                .shellDefaultHeightRatio,
            within: bounds
        )
    }
}

/// Mutable split state — ratio, shell pane instance, and
/// drag-preview bookkeeping. Backed by `@StateObject` on
/// `TerminalTabSplitView` so it persists across SwiftUI
/// re-renders but is rebuilt cleanly when the view
/// identity changes (e.g., session removed).
final class SplitState: ObservableObject {
    /// Where the divider sits, committed and mid-drag.
    ///
    /// One published value rather than three properties kept in step by hand,
    /// so every mutation of it announces itself to the view.
    @Published var split = PaneSplitRatio()

    @Published var shellPane: ShellTerminalPane?

    func openShell(for session: Session) {
        let pane = ShellTerminalPane(session: session)

        // Close the pane on process exit (natural exit via
        // `exit` / Ctrl+D, or forced close via SIGTERM).
        pane.onProcessExit = { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeShell()
            }
        }

        // Shell bell is fully pane-local (sound + local
        // visual flash) — `ShellTerminalPane.handleBell`
        // consumes it internally. No SessionManager
        // pipeline, no sidebar flash, no notification:
        // those belong to Claude-attention events, not
        // user-driven shell events like backspace at
        // line start.

        pane.start()
        split.ratio = TerminalTabSplitView.configuredTopRatio()
        shellPane = pane

        // Hand a weak ref back to the session so cross-pane
        // coordinators (SessionManager's session-switch focus
        // suppression) can find the shell pane from the session
        // model alone. Auto-clears on close because
        // `SplitState.shellPane = nil` is the strong release.
        session.shellPane = pane

        // Focus the shell on open (user just asked for it).
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.05
        ) {
            pane.focus()
        }
    }

    func closeShell() {
        guard let session = shellPane?.session else {
            shellPane = nil
            return
        }
        shellPane = nil
        // Return focus to the session pane. Routes through
        // the session host's `requestFocus()` so an open
        // scrollback overlay receives focus rather than the
        // hidden live terminal underneath — without this,
        // Esc would have nowhere to go and the user would
        // be stuck in scrollback.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.05
        ) {
            session.paneRegistry.restoreFocus(kind: .session)
        }
    }
}

/// Pub/sub hub for Terminal-tab commands from the menu.
/// Each `TerminalTabSplitView` subscribes and filters by
/// session ID, so only the active session's split
/// responds. Singleton lifetime — installed once at first
/// access; Cmd+W monitor is hooked here too.
final class TerminalTabCommands {
    static let shared = TerminalTabCommands()

    let openShell = PassthroughSubject<UUID, Never>()
    let focusSession = PassthroughSubject<UUID, Never>()
    let closeFocusedShell =
        PassthroughSubject<UUID, Never>()

    /// Strong ref kept so the monitor is never removed for
    /// the life of the app.
    private var cmdWMonitor: Any?

    private init() {
        installCmdWMonitor()
    }

    /// Install an app-wide Cmd+W interceptor that consumes
    /// the event only when the first responder is inside a
    /// `TerminalHostView` hosting a `ShellTerminalPane`. In
    /// that case, sends `closeFocusedShell` for the owning
    /// session. Otherwise passes through so the File menu's
    /// Cmd+W handles it as before.
    private func installCmdWMonitor() {
        cmdWMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self = self else { return event }
            let modsOfInterest: NSEvent.ModifierFlags = [
                .command, .option, .control, .shift,
            ]
            let mods =
                event.modifierFlags
                .intersection(modsOfInterest)
            guard mods == .command else { return event }
            guard
                event.charactersIgnoringModifiers?
                    .lowercased() == "w"
            else { return event }

            guard let window = NSApp.keyWindow,
                  let responder =
                    window.firstResponder as? NSView
            else { return event }

            var view: NSView? = responder
            while let v = view {
                if let host = v as? TerminalHostView,
                   let shellPane =
                    host.pane as? ShellTerminalPane,
                   let sessionId =
                    shellPane.session?.id {
                    self.closeFocusedShell.send(sessionId)
                    return nil  // consume the event
                }
                view = v.superview
            }
            return event
        }
    }
}
