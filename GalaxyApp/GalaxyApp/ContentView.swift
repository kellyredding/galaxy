import SwiftUI
import AppKit
import Combine
import Galactic

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.chromeFontSize) private var chromeFontSize

    /// Narrow publisher for sidebar visibility. Observes only
    /// the visibility flip — not the rest of the settings
    /// model — so toggling no longer invalidates every
    /// SettingsManager consumer in the tree. See
    /// `SidebarPreferences` for the rationale.
    @ObservedObject private var sidebarPrefs
        = SidebarPreferences.shared

    /// Presentation state for ⌘/. Observed here because the overlay
    /// lives in this body; a flip invalidates the whole root body,
    /// which is acceptable at twice per ⌘/ — the six tab containers
    /// are constructed on every body pass regardless, since they are
    /// switched by opacity rather than by branching.
    @ObservedObject private var cheatSheet
        = CheatSheetPresenter.shared

    /// Presentation state for ⇧⌘I, observed for the same reason as ⌘/ above.
    @ObservedObject private var inboxModal
        = AgentInboxPresenter.shared

    // Track width during drag (nil when not dragging, uses settings value)
    @State private var draggingWidth: CGFloat? = nil

    /// Observes the active session's navigation history so
    /// back/forward button enabled-states and dropdown contents
    /// update reactively when history changes. Rebinds on
    /// session switch.
    @StateObject private var historyObserver
        = HistoryObserverBridge()

    private let toolbarHeight: CGFloat = 28
    private let collapsedSidebarWidth: CGFloat = 32
    private let historyNavButtonsWidth: CGFloat = 54

    private var isSidebarVisible: Bool {
        sidebarPrefs.isVisible
    }

    private var sidebarWidth: CGFloat {
        // Use live dragging width if actively dragging, otherwise use persisted setting
        draggingWidth ?? settingsManager.settings.sidebarWidth
    }

    /// Effective width of the sidebar column. When dragging, uses the
    /// live drag value. When expanded, uses the persisted setting.
    /// When collapsed, uses the fixed collapsed width.
    private var sidebarColumnWidth: CGFloat {
        if isSidebarVisible {
            return draggingWidth ?? settingsManager.settings.sidebarWidth
        } else {
            return collapsedSidebarWidth
        }
    }

    /// The currently active session (for terminal font control)
    private var activeSession: Session? {
        guard let activeId = sessionManager.activeSessionId else { return nil }
        return sessionManager.sessions.first { $0.id == activeId }
    }

    private var sidebarOnLeft: Bool {
        settingsManager.settings.sidebarPosition == .left
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarOnLeft {
                sidebarColumn
                resizeHandle
                viewsColumn
            } else {
                viewsColumn
                resizeHandle
                sidebarColumn
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        // Mounted on the root HStack, above both columns, so ⌘/ reaches
        // it from any of the six tabs and from the sidebar alike — and
        // outside the inactive dimming the views column applies, because
        // a reference should stay legible.
        //
        // The HStack rather than either column: `viewsColumn` and
        // `sidebarColumn` are order-swapped by `sidebarOnLeft`, so a
        // sheet anchored to a column would slide across the window when
        // the user moved the sessions panel. After `.frame` so the scrim
        // covers the whole window; before `.environment` so the sheet
        // sits inside the same environment as the rest of the tree.
        .overlay {
            if cheatSheet.isPresented {
                CheatSheetView()
                    .transition(.opacity)
            }
        }
        .animation(
            .easeInOut(duration: 0.12), value: cheatSheet.isPresented
        )
        // Mounted alongside the cheat sheet and for the same reasons: ⇧⌘I
        // reaches it from any of the six tabs, and what is waiting to be sent
        // should stay legible outside the views column's inactive dimming —
        // that being exactly when a reader wonders whether their message went.
        .overlay {
            if inboxModal.isPresented {
                AgentInboxView()
                    .transition(.opacity)
            }
        }
        .animation(
            .easeInOut(duration: 0.12), value: inboxModal.isPresented
        )
        .environment(\.chromeFontSize, settingsManager.settings.chromeFontSize)
    }

    // MARK: - Sidebar Column

    private var sidebarControlBar: some View {
        HStack(spacing: 0) {
            if sidebarOnLeft {
                sidebarToggleButton
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                sidebarToggleButton
            }
        }
        .padding(sidebarOnLeft ? .leading : .trailing, 5)
        .frame(height: toolbarHeight)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(height: 1)
        }
    }

    private var sidebarToggleButton: some View {
        Button(action: {
            sidebarPrefs.togglePreferred()
        }) {
            Image(systemName: sidebarOnLeft ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 14))
                .foregroundColor(isSidebarVisible ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(isSidebarVisible ? "Hide Sessions" : "Show Sessions")
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            sidebarControlBar
            // Both sidebar views stay in the tree at all
            // times; visibility is gated by opacity rather
            // than a conditional swap. The previous
            // `if isSidebarVisible { … } else { … }`
            // forced SwiftUI to construct the destination
            // subtree (20 rows + layout + NSHostingView
            // wrapping) synchronously before `withAnimation`
            // could compute a start/end pair to interpolate.
            // With both subtrees pre-built, the toggle is a
            // bare opacity change with nothing to construct
            // first. It is not animated: the slide came out
            // with the rebuild and stayed out, because
            // SwiftUI's cadence caps at 30Hz on a
            // non-ProMotion display and a snap reads better
            // than a stutter.
            //
            // Lifecycle note: `onAppear` / `onDisappear` on
            // these two children fire once at parent load,
            // not on every toggle. New code that needs
            // per-show work must observe `isSidebarVisible`
            // explicitly rather than relying on the appear
            // hooks.
            ZStack {
                ExpandedSessionSidebar()
                .opacity(isSidebarVisible ? 1 : 0)
                .allowsHitTesting(isSidebarVisible)

                CollapsedSessionSidebar()
                    .opacity(isSidebarVisible ? 0 : 1)
                    .allowsHitTesting(!isSidebarVisible)
            }
        }
        .frame(width: sidebarColumnWidth)
        .clipped()
        .transaction { t in
            // Disable animations during sidebar resize drag
            if draggingWidth != nil {
                t.animation = nil
            }
        }
    }

    // MARK: - Views Column

    private var viewsControlBar: some View {
        HStack(spacing: 8) {
            historyNavButtons
            Spacer()
            tabPicker
            Spacer()
            // Balancing spacer so tabPicker stays centered
            // relative to the full control bar width.
            Color.clear.frame(width: historyNavButtonsWidth)
        }
        .padding(.horizontal, 8)
        .frame(height: toolbarHeight)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(height: 1)
        }
        .onAppear {
            historyObserver.rebind(
                to: activeSession?.navigationCoordinator
                    .history
            )
        }
        .onChange(of: sessionManager.activeSessionId) {
            historyObserver.rebind(
                to: activeSession?.navigationCoordinator
                    .history
            )
        }
    }

    @ViewBuilder
    private var historyNavButtons: some View {
        if let session = activeSession {
            HStack(spacing: 2) {
                LongPressMenuButton(
                    systemImage: "chevron.backward",
                    help: "Back ⌘[",
                    isEnabled: session
                        .navigationCoordinator
                        .history.canGoBack,
                    menuItems: {
                        session.navigationCoordinator
                            .history.backEntries
                            .map {
                                LongPressMenuItem(
                                    id: $0.id,
                                    title: $0.displayTitle,
                                    systemImage: nil
                                )
                            }
                    },
                    onClick: {
                        session.navigationCoordinator
                            .navigateBack()
                    },
                    onSelect: { entryId in
                        session.navigationCoordinator
                            .jumpTo(entryId: entryId)
                    }
                )
                .frame(width: 24, height: 20)

                LongPressMenuButton(
                    systemImage: "chevron.forward",
                    help: "Forward ⌘]",
                    isEnabled: session
                        .navigationCoordinator
                        .history.canGoForward,
                    menuItems: {
                        session.navigationCoordinator
                            .history.forwardEntries
                            .map {
                                LongPressMenuItem(
                                    id: $0.id,
                                    title: $0.displayTitle,
                                    systemImage: nil
                                )
                            }
                    },
                    onClick: {
                        session.navigationCoordinator
                            .navigateForward()
                    },
                    onSelect: { entryId in
                        session.navigationCoordinator
                            .jumpTo(entryId: entryId)
                    }
                )
                .frame(width: 24, height: 20)
            }
            .frame(
                width: historyNavButtonsWidth,
                alignment: .leading
            )
        } else {
            Color.clear
                .frame(width: historyNavButtonsWidth)
        }
    }

    private var viewsColumn: some View {
        VStack(spacing: 0) {
            viewsControlBar
            activeViewContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var activeViewContent: some View {
        if sessionManager.sessions.isEmpty {
            EmptyStateView()
        } else {
            ZStack {
                TerminalContainerView()
                    .tabPane(.terminal, selected: sessionManager.activeTab)

                LedgerContainerView()
                    .tabPane(.ledger, selected: sessionManager.activeTab)

                AgentsContainerView()
                    .tabPane(.agents, selected: sessionManager.activeTab)

                ArtifactsContainerView()
                    .tabPane(.artifacts, selected: sessionManager.activeTab)

                SnapshotsContainerView()
                    .tabPane(.snapshots, selected: sessionManager.activeTab)

                TimelineContainerView()
                    .tabPane(.timeline, selected: sessionManager.activeTab)

                FilesContainerView()
                    .tabPane(.files, selected: sessionManager.activeTab)
            }
            .onAppear {
                #if DEBUG
                    TabPaneRegistry.reportMissingPanes()
                #endif
            }
        }
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        // Leading the row rather than inside it, and an overlay rather than an
        // HStack member, because the glyph comes and goes with the queue: as a
        // member it would shove the tabs sideways every time a message queued
        // and again when it drained. An overlay takes part in no layout, so
        // the tabs sit exactly where they always did.
        //
        // Sized as a tab, and coloured as one: muted at rest like a tab you
        // are not on, and taking the selected tab's colour under the pointer.
        // It is a sibling of these controls rather than an annotation on them,
        // so it answers to the same two states they do.
        tabRow
            .overlay(alignment: .leading) {
                if let session = activeSession {
                    AgentInboxIndicator(
                        inbox: session.inbox,
                        size: ChromeFontSize(chromeFontSize).caption2,
                        tint: .secondary,
                        hoverTint: .primary,
                        onOpen: { AgentInboxPresenter.shared.toggle() }
                    )
                    .offset(x: -22)
                }
            }
    }

    private var tabRow: some View {
        HStack(spacing: 0) {
            ForEach(SessionTab.allCases, id: \.self) { tab in
                Button(action: { sessionManager.activeTab = tab }) {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                        Text(tab.title)
                    }
                    .chromeFont(size: ChromeFontSize(chromeFontSize).caption2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                sessionManager.activeTab == tab
                                    ? Color.primary.opacity(0.1)
                                    : Color.clear
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(
                    sessionManager.activeTab == tab ? .primary : .secondary
                )
                .overlay(alignment: .topLeading) {
                    if tab == .terminal, let session = activeSession {
                        TabUnreadIndicator(
                            session: session,
                            sessionId: session.id,
                            showUnreadIndicator: settingsManager.settings.showUnreadIndicator,
                            isWindowFocused: sessionManager.isWindowFocused,
                            isOnTerminalTab: sessionManager.activeTab == .terminal
                        )
                        .withClearBehavior()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if tab == .agents,
                       let session = activeSession
                    {
                        AgentRunningBadge(
                            session: session
                        )
                        .offset(x: -2, y: -2)
                    }
                }
            }
        }
    }

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 1)
            .overlay {
                // Invisible drag handle — only when sidebar is expanded
                if isSidebarVisible {
                    SidebarResizeHandle(
                        currentWidth: sidebarWidth,
                        sidebarOnLeft: sidebarOnLeft,
                        onWidthChange: { newWidth in
                            draggingWidth = newWidth
                        },
                        onDragEnd: { finalWidth in
                            settingsManager.settings.sidebarWidth = finalWidth
                            draggingWidth = nil
                        }
                    )
                    .frame(width: 9)
                }
            }
            .zIndex(100)
    }
}

/// Forwards `objectWillChange` from the active session's
/// `SessionNavigationHistory` so ContentView re-renders
/// back/forward button enabled-states when history mutates.
///
/// Needed because ContentView observes `Session` (via
/// `activeSession`) but not the nested
/// `navigationCoordinator.history` — SwiftUI doesn't follow
/// nested ObservableObject chains automatically.
final class HistoryObserverBridge: ObservableObject {
    private var cancellable: AnyCancellable?

    func rebind(to history: SessionNavigationHistory?) {
        cancellable = history?.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
    }
}

struct EmptyStateView: View {
    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme

    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    /// Background color matching terminal emulator (black in dark, white in light)
    private var terminalBackground: Color {
        colorScheme == .dark ? .black : .white
    }

    /// Text color for contrast against terminal background
    private var terminalForeground: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        ZStack {
            // Background with watermark
            terminalBackground
            WatermarkBackground()

            // Content
            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .chromeFont(size: fontSize.iconLarge)
                    .foregroundColor(.secondary)

                Text("No sessions")
                    .chromeFont(size: fontSize.title2)
                    .foregroundColor(terminalForeground)

                Text("Run `galaxy` from any directory to start a session")
                    .chromeFont(size: fontSize.body)
                    .foregroundColor(.secondary)

                Text("cd ~/projects/my-app && galaxy")
                    .chromeFontMono(size: fontSize.body)
                    .padding(8)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()  // Clip watermark to content area bounds
    }
}

struct TerminalContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        ZStack {
            ForEach(sessionManager.sessions) { session in
                TerminalTabSplitView(
                    session: session,
                    isActiveSession:
                        session.id == sessionManager.activeSessionId,
                    // Both halves, composed once at the top. Everything below
                    // reads this rather than re-deriving a piece of it.
                    isVisibleSurface:
                        session.id == sessionManager.activeSessionId
                        && sessionManager.activeTab == .terminal,
                    onResume: { sessionManager.resumeSession(sessionId: session.id) }
                )
                .opacity(session.id == sessionManager.activeSessionId ? 1 : 0)
                .allowsHitTesting(session.id == sessionManager.activeSessionId)
                .zIndex(session.id == sessionManager.activeSessionId ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: sessionManager.activeTab) {
            if sessionManager.activeTab == .terminal {
                restoreTerminalFocus()
            } else {
                releaseTerminalFocus()
            }
        }
        .onChange(of: sessionManager.activeSessionId) {
            if sessionManager.activeTab == .terminal {
                restoreTerminalFocus()
            }
        }
    }

    /// Let go of first responder when the terminal stops being the surface
    /// the user is on.
    ///
    /// The counterpart to `restoreTerminalFocus`, and its absence was a
    /// bug rather than a decision: every tab container stays mounted, so
    /// leaving the Terminal tab left the caret in a terminal the user
    /// could no longer see. A key equivalent carrying no modifier loses to
    /// whatever holds first responder, so Return on the Artifacts tab went
    /// to the hidden terminal as a newline instead of opening the focused
    /// artifact — the menu item was enabled the whole time and never got
    /// the event.
    ///
    /// Each pane decides whether it actually holds focus, so this is safe
    /// when the answer is already no.
    private func releaseTerminalFocus() {
        guard let activeId = sessionManager.activeSessionId,
              let session = sessionManager.sessions
                .first(where: { $0.id == activeId })
        else { return }
        session.paneRegistry.resignPaneFocus()
    }

    /// Restore AppKit first responder to the active session's
    /// preferred pane (whichever one was last focused — Session
    /// or Shell).  Tab/session switching via ZStack opacity
    /// toggling doesn't trigger FocusableTerminalView.updateNSView
    /// (inputs unchanged), so the terminal loses first responder
    /// when hidden and doesn't regain it. Routes through Session's
    /// pane-focus registry, which lets each TerminalHostView's
    /// requestFocus() handle scrollback state internally.
    ///
    /// Called synchronously rather than through asyncAfter — the
    /// inner DispatchQueue.main.async + retry inside
    /// TerminalHostView.requestFocus already handles the
    /// "view-not-yet-in-window" case the previous 50ms outer wait
    /// targeted, and that 50ms consistently slipped to ~180ms
    /// because the main thread was busy with AppKit draw work
    /// after the switch.
    private func restoreTerminalFocus() {
        guard let activeId = sessionManager.activeSessionId,
              let session = sessionManager.sessions
                .first(where: { $0.id == activeId }),
              !session.hasExited else { return }
        session.paneRegistry.restorePreferredPaneFocus()
    }
}

/// Observes a session's hasUnreadResponse so the tab picker re-renders
/// reactively. Without @ObservedObject, the computed-property chain
/// in ContentView doesn't establish SwiftUI observation.
/// Also attaches UnreadIndicatorBehavior to auto-clear when viewing terminal.
struct TabUnreadIndicator: View {
    @ObservedObject var session: Session
    let sessionId: UUID
    let showUnreadIndicator: Bool
    let isWindowFocused: Bool
    let isOnTerminalTab: Bool

    var body: some View {
        UnreadIndicator()
            .offset(x: 4, y: 2)
            .opacity(session.hasUnreadResponse && showUnreadIndicator ? 1 : 0)
            .animation(
                session.hasUnreadResponse ? nil : .easeOut(duration: 3.0),
                value: session.hasUnreadResponse
            )
    }
}

extension TabUnreadIndicator {
    /// Attach auto-clear behavior so the tab dot clears independently
    /// of the sidebar row (which has its own behavior modifier).
    func withClearBehavior() -> some View {
        // The tab indicator only ever renders for the active session, so
        // selection is a given here and being viewed reduces to focus and tab.
        self.attentionAutoClear(
            isBeingViewed: isWindowFocused && isOnTerminalTab,
            hasAttention: session.hasUnreadResponse
        ) {
            session.hasUnreadResponse = false
        }
    }
}


// MARK: - Sidebar Resize Handle (AppKit-based for smooth dragging)

/// NSViewRepresentable wrapper for smooth mouse-tracked sidebar resizing.
/// Uses AppKit's direct mouse events instead of SwiftUI's DragGesture for better performance.
struct SidebarResizeHandle: NSViewRepresentable {
    let currentWidth: CGFloat
    let sidebarOnLeft: Bool
    let onWidthChange: (CGFloat) -> Void
    let onDragEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let view = ResizeHandleNSView()
        view.sidebarOnLeft = sidebarOnLeft
        view.onWidthChange = onWidthChange
        view.onDragEnd = onDragEnd
        return view
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        nsView.currentWidth = currentWidth
        nsView.sidebarOnLeft = sidebarOnLeft
        nsView.onWidthChange = onWidthChange
        nsView.onDragEnd = onDragEnd
    }
}

/// AppKit NSView that handles mouse events directly for smooth resize dragging.
/// This view is transparent - SwiftUI handles the visual separator line.
class ResizeHandleNSView: NSView {
    var currentWidth: CGFloat = 220
    var sidebarOnLeft: Bool = true
    var onWidthChange: ((CGFloat) -> Void)?
    var onDragEnd: ((CGFloat) -> Void)?

    private var isDragging = false
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Transparent - no visual, just mouse handling
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isDragging {
            NSCursor.resizeLeftRight.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStartX = NSEvent.mouseLocation.x
        dragStartWidth = currentWidth
        NSCursor.closedHand.set()  // Grabbing cursor
        StatusLineService.shared.pauseUpdates()  // Pause for performance
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        NSCursor.closedHand.set()  // Reinforce cursor during drag

        let currentX = NSEvent.mouseLocation.x
        let delta = currentX - dragStartX

        // When sidebar is on left, dragging right increases width
        // When sidebar is on right, dragging left increases width
        let newWidth: CGFloat
        if sidebarOnLeft {
            newWidth = dragStartWidth + delta
        } else {
            newWidth = dragStartWidth - delta
        }

        // Clamp to allowed range
        let clamped = min(max(newWidth, AppSettings.sidebarWidthRange.lowerBound),
                          AppSettings.sidebarWidthRange.upperBound)
        onWidthChange?(clamped)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.arrow.set()  // Reset cursor, tracking area will update if still hovering
        StatusLineService.shared.resumeUpdates()  // Resume after drag

        // Calculate final width
        let currentX = NSEvent.mouseLocation.x
        let delta = currentX - dragStartX
        let newWidth: CGFloat
        if sidebarOnLeft {
            newWidth = dragStartWidth + delta
        } else {
            newWidth = dragStartWidth - delta
        }
        let clamped = min(max(newWidth, AppSettings.sidebarWidthRange.lowerBound),
                          AppSettings.sidebarWidthRange.upperBound)
        onDragEnd?(clamped)
    }
}
