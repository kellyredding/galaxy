import SwiftUI
import AppKit

struct SessionSidebar: View {
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject var statusLineService = StatusLineService.shared
    @StateObject private var dragCoordinator = SessionDragCoordinator()

    // Row height for drag calculations (must match SessionRow layout)
    private let rowHeight: CGFloat = 44

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
                                    onStop: {
                                        sessionManager.stopSession(sessionId: session.id)
                                    },
                                    onClose: {
                                        sessionManager.closeSession(sessionId: session.id)
                                    },
                                    isPlaceholder: dragCoordinator.draggedSessionId == session.id,
                                    rowIndex: index,
                                    showDragHandle: showDragHandles,
                                    isDragging: dragCoordinator.isDragging,
                                    statusInfo: statusLineService.statusInfo[session.id]
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

                        // Drag preview - inside scroll content, positioned with offset
                        // APPROACH 2: Position based on dragStartIndex (fixed) + mouse offset
                        // This decouples preview position from array swaps for smooth dragging
                        if dragCoordinator.isDragging,
                           let draggedId = dragCoordinator.draggedSessionId,
                           let session = sessionManager.sessions.first(where: { $0.id == draggedId }) {

                            // Use currentArrayIndex for rowIndex display, but position based on dragStartIndex
                            let displayIndex = dragCoordinator.currentArrayIndex

                            SessionRow(
                                session: session,
                                isSelected: session.id == sessionManager.activeSessionId,
                                isWindowFocused: sessionManager.isWindowFocused,
                                onStop: {},
                                onClose: {},
                                isPlaceholder: false,
                                rowIndex: displayIndex,
                                showDragHandle: true,
                                isDragging: true,
                                statusInfo: statusLineService.statusInfo[session.id]
                            )
                            .environmentObject(dragCoordinator)  // Inject for SessionRowDragHandle
                            .background(Color(NSColor.windowBackgroundColor))
                            .overlay(
                                Rectangle()
                                    .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                            )
                            // Position preview at: startPosition + mouseOffset (independent of swaps)
                            .offset(y: CGFloat(dragCoordinator.dragStartIndex) * rowHeight + dragCoordinator.dragOffsetY)
                            .zIndex(1000)  // Above all other content
                            .allowsHitTesting(false)
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
        // Width is controlled by ContentView via settingsManager.settings.sidebarWidth
        // Note: sidebar frame for auto-scroll is captured by DragHandleNSView during drag
        .onChange(of: sessionManager.sessions.count) { _, newCount in
            // Update drag coordinator with new count and session IDs
            dragCoordinator.totalSessionCount = newCount
            dragCoordinator.sessionIds = sessionManager.sessions.map { $0.id }
            // Restart monitoring when sessions change
            statusLineService.startMonitoring(sessions: sessionManager.sessions)
        }
        .onAppear {
            // Configure drag coordinator
            dragCoordinator.rowHeight = rowHeight
            dragCoordinator.totalSessionCount = sessionManager.sessions.count
            dragCoordinator.sessionIds = sessionManager.sessions.map { $0.id }
            dragCoordinator.onSwapNeeded = { fromIndex, toIndex in
                sessionManager.swapSessions(fromIndex, toIndex)
            }

            // Start monitoring on appear
            if !sessionManager.sessions.isEmpty {
                statusLineService.startMonitoring(sessions: sessionManager.sessions)
            }
        }
        .onDisappear {
            statusLineService.stopMonitoring()
        }
    }
}
