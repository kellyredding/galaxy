import SwiftUI
import AppKit

struct ExpandedSessionSidebar: View {
    // `sidebarWidth` removed — the rows beneath this view
    // (SessionRow, SessionMarkerRow) no longer need an
    // explicit width parameter; their adaptive truncation
    // is driven by SwiftUI layout via ViewThatFits. The
    // outer container's width is managed by ContentView's
    // `.frame(width: sidebarColumnWidth)` and SwiftUI's
    // HStack distribution; nothing inside this view tree
    // reads an explicit width any more.

    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject var statusLineService = StatusLineService.shared
    @StateObject private var dragCoordinator = SessionDragCoordinator()

    @Environment(\.chromeFontSize) private var chromeFontSize

    /// Single source of truth for sidebar row height. Both
    /// SessionRow and SessionMarkerRow consume the same value via
    /// ChromeFontSize.sidebarRowHeight, so the drag coordinator's
    /// uniform-height math stays valid across both row kinds.
    private var rowHeight: CGFloat {
        ChromeFontSize(chromeFontSize).sidebarRowHeight
    }

    /// Show drag handles when there's more than one item in the
    /// sidebar — sessions and markers count equally.
    private var showDragHandles: Bool {
        sessionManager.sidebarItems.count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // Interleaved sidebar list (sessions + markers)
                        LazyVStack(spacing: 0) {
                            ForEach(
                                Array(sessionManager.sidebarItems.enumerated()),
                                id: \.element.id
                            ) { index, item in
                                rowView(for: item, at: index)
                            }
                        }
                        .environmentObject(dragCoordinator)  // Inject for SessionRowDragHandle

                        // Drag preview — isolated into its own view so the
                        // high-frequency offsetY updates only re-render
                        // the preview, not the entire sidebar.
                        if dragCoordinator.isDragging,
                           let draggedId = dragCoordinator.draggedItemId,
                           let item = sessionManager.sidebarItems.first(
                               where: { $0.id == draggedId }
                           )
                        {
                            dragPreview(for: item)
                        }
                    }
                }
                .onChange(of: sessionManager.activeSessionId) { _, newId in
                    // Auto-scroll to active session when it changes (not during drag)
                    if let id = newId, !dragCoordinator.isDragging {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scrollProxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    // Set up auto-scroll callback (captures scrollProxy)
                    dragCoordinator.onScrollToSession = { sessionId in
                        withAnimation(.easeOut(duration: 0.1)) {
                            scrollProxy.scrollTo(sessionId, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))  // Solid background to prevent watermark bleed
        // Width is controlled by ContentView via settingsManager.settings.sidebarWidth
        // Note: sidebar frame for auto-scroll is captured by DragHandleNSView during drag
        .onChange(of: chromeFontSize) { _, _ in
            // Keep drag coordinator in sync when chrome font size changes
            dragCoordinator.rowHeight = rowHeight
        }
        .onChange(of: sessionManager.sidebarItems.count) { _, newCount in
            // Update drag coordinator with new count and item IDs
            dragCoordinator.totalItemCount = newCount
            dragCoordinator.itemIds = sessionManager.sidebarItems.map { $0.id }
            // Refresh git status when session count changes
            statusLineService.refreshSessions(sessionManager.sessions)
        }
        .onAppear {
            // Configure drag coordinator
            dragCoordinator.rowHeight = rowHeight
            dragCoordinator.totalItemCount = sessionManager.sidebarItems.count
            dragCoordinator.itemIds = sessionManager.sidebarItems.map { $0.id }
            dragCoordinator.onSwapNeeded = { fromIndex, toIndex in
                sessionManager.swapItems(fromIndex, toIndex)
            }

            // Initial git status fetch on appear
            if !sessionManager.sessions.isEmpty {
                statusLineService.refreshSessions(sessionManager.sessions)
            }
        }
    }

    // MARK: - Row dispatch

    /// Returns the appropriate sidebar row view for a SidebarItem.
    /// Sessions are tappable (switch active session) and have full
    /// status content; markers are not selectable and just render
    /// their name/lines.
    @ViewBuilder
    private func rowView(for item: SidebarItem, at index: Int) -> some View {
        switch item {
        case .session(let session):
            SessionRow(
                session: session,
                isSelected: session.id == sessionManager.activeSessionId,
                isWindowFocused: sessionManager.isWindowFocused,
                isOnTerminalTab: sessionManager.activeTab == .terminal,
                onStop: {
                    sessionManager.confirmAndStopSession(sessionId: session.id)
                },
                onClose: {
                    sessionManager.confirmAndDismissSession(sessionId: session.id)
                },
                isPlaceholder: dragCoordinator.draggedItemId == session.id,
                rowIndex: index,
                showDragHandle: showDragHandles,
                isDragging: dragCoordinator.isDragging,
                statusInfo: statusLineService.statusInfo[session.id]
            )
            // Opt into SwiftUI's Equatable short-circuit so
            // parent body re-evals during a sidebar resize
            // drag don't cascade into 20 SessionRow body
            // re-evals when none of the row's inputs
            // actually changed.
            .equatable()
            .id(session.id)
            .animation(.easeInOut(duration: 0.2), value: showDragHandles)
            .contentShape(Rectangle())
            .onTapGesture {
                sessionManager.switchTo(sessionId: session.id)
            }
            .animation(.easeInOut(duration: 0.15), value: index)

        case .marker(let marker):
            SessionMarkerRow(
                marker: marker,
                onRemove: {
                    sessionManager.confirmAndRemoveMarker(markerId: marker.id)
                },
                isPlaceholder: dragCoordinator.draggedItemId == marker.id,
                rowIndex: index,
                showDragHandle: showDragHandles,
                isDragging: dragCoordinator.isDragging
            )
            .equatable()
            .id(marker.id)
            .animation(.easeInOut(duration: 0.2), value: showDragHandles)
            // No onTapGesture — markers are not selectable.
            .animation(.easeInOut(duration: 0.15), value: index)
        }
    }

    /// Returns the floating drag preview overlay for the dragged
    /// item. Dispatches on item kind so sessions and markers each
    /// render their own row body during drag.
    @ViewBuilder
    private func dragPreview(for item: SidebarItem) -> some View {
        switch item {
        case .session(let session):
            DragPreviewOverlay(
                session: session,
                isSelected: session.id == sessionManager.activeSessionId,
                isWindowFocused: sessionManager.isWindowFocused,
                isOnTerminalTab: sessionManager.activeTab == .terminal,
                displayIndex: dragCoordinator.currentArrayIndex,
                dragStartIndex: dragCoordinator.dragStartIndex,
                rowHeight: rowHeight,
                statusInfo: statusLineService.statusInfo[session.id],
                previewPosition: dragCoordinator.previewPosition
            )
            .environmentObject(dragCoordinator)

        case .marker(let marker):
            MarkerDragPreviewOverlay(
                marker: marker,
                displayIndex: dragCoordinator.currentArrayIndex,
                dragStartIndex: dragCoordinator.dragStartIndex,
                rowHeight: rowHeight,
                previewPosition: dragCoordinator.previewPosition
            )
            .environmentObject(dragCoordinator)
        }
    }
}

// MARK: - Drag Preview Overlays

/// Floating preview row shown during drag-to-reorder for a session.
/// Observes DragPreviewPosition (high-frequency offsetY) independently
/// so per-frame mouse updates only re-render this single view —
/// not the entire sidebar body and all session rows.
struct DragPreviewOverlay: View {
    @ObservedObject var session: Session
    let isSelected: Bool
    let isWindowFocused: Bool
    let isOnTerminalTab: Bool
    let displayIndex: Int
    let dragStartIndex: Int
    let rowHeight: CGFloat
    let statusInfo: StatusLineService.SessionStatusInfo?

    @ObservedObject var previewPosition: DragPreviewPosition

    var body: some View {
        SessionRow(
            session: session,
            isSelected: isSelected,
            isWindowFocused: isWindowFocused,
            isOnTerminalTab: isOnTerminalTab,
            onStop: {},
            onClose: {},
            isPlaceholder: false,
            rowIndex: displayIndex,
            showDragHandle: true,
            isDragging: true,
            statusInfo: statusInfo
        )
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            Rectangle()
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
        )
        .offset(
            y: CGFloat(dragStartIndex) * rowHeight
                + previewPosition.offsetY
        )
        .zIndex(1000)
        .allowsHitTesting(false)
    }
}

/// Floating preview row shown during drag-to-reorder for a marker.
/// Mirrors DragPreviewOverlay's positioning math so sessions and
/// markers feel identical to drag.
struct MarkerDragPreviewOverlay: View {
    @ObservedObject var marker: SessionMarker
    let displayIndex: Int
    let dragStartIndex: Int
    let rowHeight: CGFloat

    @ObservedObject var previewPosition: DragPreviewPosition

    var body: some View {
        SessionMarkerRow(
            marker: marker,
            onRemove: {},
            isPlaceholder: false,
            rowIndex: displayIndex,
            showDragHandle: true,
            isDragging: true
        )
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            Rectangle()
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
        )
        .offset(
            y: CGFloat(dragStartIndex) * rowHeight
                + previewPosition.offsetY
        )
        .zIndex(1000)
        .allowsHitTesting(false)
    }
}
