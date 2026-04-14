import SwiftUI
import AppKit

struct ExpandedSessionSidebar: View {
    let sidebarWidth: CGFloat

    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject var statusLineService = StatusLineService.shared
    @StateObject private var dragCoordinator = SessionDragCoordinator()

    @Environment(\.chromeFontSize) private var chromeFontSize

    // Row height derived from fixed line heights (deterministic, font-independent)
    private var rowHeight: CGFloat {
        let fontSize = ChromeFontSize(chromeFontSize)
        // top(6) + caption1Line + spacing(2) + tinyLine + spacing(2) + tinyLine + bottom(7)
        return 6 + fontSize.caption1LineHeight + 2 + fontSize.tinyLineHeight + 2 + fontSize.tinyLineHeight + 7
    }

    // Only show drag handles when there's more than one session
    private var showDragHandles: Bool {
        sessionManager.sessions.count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // Session list
                        LazyVStack(spacing: 0) {
                            ForEach(Array(sessionManager.sessions.enumerated()), id: \.element.id) { index, session in
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
                                    isPlaceholder: dragCoordinator.draggedSessionId == session.id,
                                    rowIndex: index,
                                    showDragHandle: showDragHandles,
                                    isDragging: dragCoordinator.isDragging,
                                    statusInfo: statusLineService.statusInfo[session.id],
                                    sidebarWidth: sidebarWidth
                                )
                                .id(session.id)
                                .animation(.easeInOut(duration: 0.2), value: showDragHandles)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    sessionManager.switchTo(sessionId: session.id)
                                }
                                .animation(.easeInOut(duration: 0.15), value: index)
                            }
                        }
                        .environmentObject(dragCoordinator)  // Inject for SessionRowDragHandle

                        // Drag preview — isolated into its own view so the
                        // high-frequency offsetY updates only re-render
                        // the preview, not the entire sidebar.
                        if dragCoordinator.isDragging,
                           let draggedId = dragCoordinator.draggedSessionId,
                           let session = sessionManager.sessions.first(where: { $0.id == draggedId }) {

                            DragPreviewOverlay(
                                session: session,
                                isSelected: session.id == sessionManager.activeSessionId,
                                isWindowFocused: sessionManager.isWindowFocused,
                                isOnTerminalTab: sessionManager.activeTab == .terminal,
                                displayIndex: dragCoordinator.currentArrayIndex,
                                dragStartIndex: dragCoordinator.dragStartIndex,
                                rowHeight: rowHeight,
                                statusInfo: statusLineService.statusInfo[session.id],
                                sidebarWidth: sidebarWidth,
                                previewPosition: dragCoordinator.previewPosition
                            )
                            .environmentObject(dragCoordinator)
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
        .onChange(of: sessionManager.sessions.count) { _, newCount in
            // Update drag coordinator with new count and session IDs
            dragCoordinator.totalSessionCount = newCount
            dragCoordinator.sessionIds = sessionManager.sessions.map { $0.id }
            // Refresh git status when session count changes
            statusLineService.refreshSessions(sessionManager.sessions)
        }
        .onAppear {
            // Configure drag coordinator
            dragCoordinator.rowHeight = rowHeight
            dragCoordinator.totalSessionCount = sessionManager.sessions.count
            dragCoordinator.sessionIds = sessionManager.sessions.map { $0.id }
            dragCoordinator.onSwapNeeded = { fromIndex, toIndex in
                sessionManager.swapSessions(fromIndex, toIndex)
            }

            // Initial git status fetch on appear
            if !sessionManager.sessions.isEmpty {
                statusLineService.refreshSessions(sessionManager.sessions)
            }
        }
    }
}

// MARK: - Drag Preview Overlay

/// Floating preview row shown during drag-to-reorder.
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
    let sidebarWidth: CGFloat

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
            statusInfo: statusInfo,
            sidebarWidth: sidebarWidth
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
