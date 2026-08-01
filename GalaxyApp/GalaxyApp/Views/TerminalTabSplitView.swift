import AppKit
import Combine
import SwiftUI

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

    /// Tightest allowed top-pane ratio. Below this, the top
    /// pane would be too small to be useful. Drag locks here
    /// rather than snapping past.
    private static let minRatio: CGFloat = 0.30

    /// Loosest allowed top-pane ratio. Above this, the shell
    /// pane is too small to type into.
    private static let maxRatio: CGFloat = 0.70

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
                                state.beginDragPreview()
                            },
                            onBarDrag: { delta in
                                state.updateDragPreview(
                                    cursorDeltaY: delta,
                                    totalHeight: totalHeight,
                                    minRatio: Self.minRatio,
                                    maxRatio: Self.maxRatio
                                )
                            },
                            onBarDragEnded: {
                                state.commitDragPreview()
                            },
                            onBarDoubleClick: {
                                withAnimation(
                                    .easeInOut(duration: 0.15)
                                ) {
                                    state.ratio =
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
                if let preview = state.dragPreviewRatio,
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
        let clampedRatio = min(
            max(state.ratio, Self.minRatio),
            Self.maxRatio
        )
        return totalHeight * clampedRatio
    }

    /// Top-pane fraction derived from the user's configured
    /// default shell height. Clamped against the same drag
    /// window the view enforces so the setting can never
    /// disagree with live drag bounds. Used on shell open
    /// and on double-click reset.
    static func configuredTopRatio() -> CGFloat {
        let shellRatio = SettingsManager.shared.settings
            .shellDefaultHeightRatio
        let clampedShell = min(
            max(
                shellRatio,
                AppSettings
                    .shellDefaultHeightRatioRange.lowerBound
            ),
            AppSettings
                .shellDefaultHeightRatioRange.upperBound
        )
        return CGFloat(1.0 - clampedShell)
    }
}

/// Mutable split state — ratio, shell pane instance, and
/// drag-preview bookkeeping. Backed by `@StateObject` on
/// `TerminalTabSplitView` so it persists across SwiftUI
/// re-renders but is rebuilt cleanly when the view
/// identity changes (e.g., session removed).
final class SplitState: ObservableObject {
    /// Committed split ratio — drives the actual pane
    /// layout. Only updated on drag commit, not on each
    /// cursor tick.
    @Published var ratio: CGFloat = 0.5

    /// Live drag preview ratio. Non-nil while the user is
    /// actively dragging the shell bar. The ghost line
    /// indicator reads this; the panes themselves stay at
    /// `ratio` until the drag commits.
    @Published var dragPreviewRatio: CGFloat?

    /// Snapshot of `ratio` taken at drag start. Used as the
    /// base for computing the preview ratio from the
    /// cursor delta, so repeated drag updates don't
    /// compound.
    private var dragStartRatio: CGFloat?

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
        ratio = TerminalTabSplitView.configuredTopRatio()
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

    /// Capture the current ratio as the drag-preview
    /// baseline. Called on mouseDown from the shell bar.
    /// `dragPreviewRatio` is deliberately left nil until
    /// the first `updateDragPreview` — we don't want the
    /// ghost-line indicator to appear for click-without-
    /// drag interactions.
    func beginDragPreview() {
        dragStartRatio = ratio
    }

    /// Update the drag-preview ratio based on a cursor Y
    /// delta from drag-start. Dragging the bar up (positive
    /// delta in screen coords) shrinks the top (session)
    /// pane and grows the bottom (shell) pane.
    ///
    /// Always computes from `dragStartRatio`, not the
    /// current preview — this avoids the compound-update
    /// bug that would otherwise make each tick's delta
    /// stack on top of the previous frame's adjustment.
    ///
    /// Clamps the resulting ratio to the caller-supplied
    /// `[minRatio, maxRatio]` window, so cursor movement
    /// past the threshold locks the preview at the boundary
    /// rather than continuing off into unusable territory.
    func updateDragPreview(
        cursorDeltaY: CGFloat,
        totalHeight: CGFloat,
        minRatio: CGFloat,
        maxRatio: CGFloat
    ) {
        guard totalHeight > 0,
              let startRatio = dragStartRatio else { return }
        let newTop =
            (startRatio * totalHeight) - cursorDeltaY
        let rawRatio = newTop / totalHeight
        dragPreviewRatio = min(
            max(rawRatio, minRatio),
            maxRatio
        )
    }

    /// Commit the drag preview — apply the ratio in one
    /// step so both panes' terminals reflow once, instead
    /// of on every mouseDragged tick. Clears drag state.
    ///
    /// If the user clicked without dragging,
    /// `dragPreviewRatio` will be nil and the committed
    /// ratio stays unchanged.
    func commitDragPreview() {
        if let preview = dragPreviewRatio {
            ratio = preview
        }
        dragStartRatio = nil
        dragPreviewRatio = nil
    }
}

/// Ghost line shown while the user drags the shell bar.
/// Deliberately subtle — a single thin line at the
/// proposed new divider Y, with a small floating label
/// near the right edge. Line + label both use
/// `Color.primary`, which adapts to dark/light themes
/// (white in dark, black in light).
///
/// Rendered over the (still-current-ratio) panes so
/// neither terminal reflows until the drag commits.
struct DragPreviewLineView: View {
    let shellPercentage: Int

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.85))
            .overlay(
                Text("Shell \(shellPercentage)%")
                    .font(
                        .system(size: 10, weight: .medium)
                    )
                    .foregroundColor(
                        Color.primary.opacity(0.85)
                    )
                    .fixedSize()
                    .padding(.trailing, 10)
                    .offset(y: -14),
                alignment: .trailing
            )
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
