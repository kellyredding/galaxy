import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.chromeFontSize) private var chromeFontSize

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
        settingsManager.settings.isSidebarVisible
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
            withAnimation(.easeInOut(duration: 0.2)) {
                settingsManager.settings.isSidebarVisible.toggle()
            }
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
            if isSidebarVisible {
                ExpandedSessionSidebar(sidebarWidth: sidebarColumnWidth)
            } else {
                CollapsedSessionSidebar()
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
                    .opacity(sessionManager.activeTab == .terminal ? 1 : 0)
                    .allowsHitTesting(sessionManager.activeTab == .terminal)
                    .zIndex(sessionManager.activeTab == .terminal ? 1 : 0)

                LedgerContainerView()
                    .opacity(sessionManager.activeTab == .ledger ? 1 : 0)
                    .allowsHitTesting(sessionManager.activeTab == .ledger)
                    .zIndex(sessionManager.activeTab == .ledger ? 1 : 0)

                AgentsContainerView()
                    .opacity(sessionManager.activeTab == .agents ? 1 : 0)
                    .allowsHitTesting(sessionManager.activeTab == .agents)
                    .zIndex(sessionManager.activeTab == .agents ? 1 : 0)

                ArtifactsContainerView()
                    .opacity(sessionManager.activeTab == .artifacts ? 1 : 0)
                    .allowsHitTesting(sessionManager.activeTab == .artifacts)
                    .zIndex(sessionManager.activeTab == .artifacts ? 1 : 0)

                SnapshotsContainerView()
                    .opacity(sessionManager.activeTab == .snapshots ? 1 : 0)
                    .allowsHitTesting(sessionManager.activeTab == .snapshots)
                    .zIndex(sessionManager.activeTab == .snapshots ? 1 : 0)

                TimelineContainerView()
                    .opacity(sessionManager.activeTab == .timeline ? 1 : 0)
                    .allowsHitTesting(sessionManager.activeTab == .timeline)
                    .zIndex(sessionManager.activeTab == .timeline ? 1 : 0)
            }
        }
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
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
                    isActive: session.id == sessionManager.activeSessionId,
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
            }
        }
        .onChange(of: sessionManager.activeSessionId) {
            if sessionManager.activeTab == .terminal {
                restoreTerminalFocus()
            }
        }
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
        session.restorePreferredPaneFocus()
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
        self.unreadIndicatorBehavior(
            session: session,
            isSelected: true,  // tab indicator is always for the active session
            isWindowFocused: isWindowFocused,
            isOnTerminalTab: isOnTerminalTab
        )
    }
}


/// Wrapper view that observes individual session state changes.
/// Constructs a SessionTerminalPane adapter for the running
/// branch, cached via a @StateObject so its identity is stable
/// across SwiftUI re-renders and only rebuilt when the underlying
/// GalaxyTerminalView changes (e.g., after a stop+resume cycle).
struct SessionPaneView: View {
    @ObservedObject var session: Session
    let isActive: Bool
    let onResume: () -> Void

    @StateObject private var adapterHolder = SessionPaneAdapterHolder()

    var body: some View {
        Group {
            if session.hasExited {
                // Show stopped session UI
                StoppedSessionView(session: session, onResume: onResume)
            } else if let galaxyView = session.terminalView {
                // Show terminal via TerminalPane abstraction.
                // `.equatable()` opts into our Equatable
                // conformance for SwiftUI's diff, guaranteeing
                // updateNSView is skipped on rows whose pane
                // and isActive flag haven't changed.
                FocusableTerminalView(
                    pane: adapterHolder.adapter(
                        for: session, view: galaxyView
                    ),
                    isActive: isActive
                )
                .equatable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: session.hasExited) {
            // Release the cached adapter (and its strong reference
            // to the old GalaxyTerminalView) when the session
            // stops. Without this, the ~32MB scrollback buffer
            // stays resident until the user either resumes the
            // session (which replaces the cached adapter) or
            // dismisses it (which tears down the whole
            // SessionPaneView). With it, Session.releaseTerminalView
            // can actually free the buffer at stop time, matching
            // pre-refactor behavior.
            if session.hasExited {
                adapterHolder.release()
            }
        }
    }
}

/// Caches a SessionTerminalPane adapter per SessionPaneView
/// lifetime, returning the same instance for the same underlying
/// GalaxyTerminalView. On view change (e.g., stop+resume creates
/// a fresh GalaxyTerminalView), a new adapter is constructed.
///
/// The cached adapter is stored in a non-@Published property so
/// mutating it during body evaluation doesn't re-trigger SwiftUI
/// updates.
private final class SessionPaneAdapterHolder: ObservableObject {
    private var cached: SessionTerminalPane?

    func adapter(
        for session: Session,
        view: GalaxyTerminalView
    ) -> SessionTerminalPane {
        if let cached, cached.galaxyView === view {
            return cached
        }
        let fresh = SessionTerminalPane(
            session: session, galaxyView: view
        )
        cached = fresh
        return fresh
    }

    /// Drop the cached adapter so the GalaxyTerminalView it holds
    /// strongly can be released. Called when the session stops so
    /// the scrollback buffer is freed at stop time rather than at
    /// resume or dismiss time.
    func release() {
        cached = nil
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
