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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(sessionManager.sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRow(
                            session: session,
                            statusLineService: statusLineService,
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
                            dragCoordinator: dragCoordinator
                        )
                        .animation(.easeInOut(duration: 0.2), value: showDragHandles)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            sessionManager.switchTo(sessionId: session.id)
                        }
                        .animation(.easeInOut(duration: 0.15), value: index)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                // Drag preview overlay - renders copy of dragged row on top
                if dragCoordinator.isDragging,
                   let draggedId = dragCoordinator.draggedSessionId,
                   let session = sessionManager.sessions.first(where: { $0.id == draggedId }) {

                    // Find the current index of the dragged session
                    let currentIndex = sessionManager.sessions.firstIndex(where: { $0.id == draggedId }) ?? 0

                    SessionRow(
                        session: session,
                        statusLineService: statusLineService,
                        isSelected: session.id == sessionManager.activeSessionId,
                        isWindowFocused: sessionManager.isWindowFocused,
                        onStop: {},
                        onClose: {},
                        isPlaceholder: false,  // Preview shows full content
                        rowIndex: currentIndex,
                        showDragHandle: true,  // Always show handle in preview
                        dragCoordinator: dragCoordinator
                    )
                    .background(Color(NSColor.windowBackgroundColor))  // Solid background for preview
                    .overlay(
                        Rectangle()
                            .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    )
                    .offset(y: CGFloat(currentIndex) * rowHeight + dragCoordinator.dragOffsetY)
                    .allowsHitTesting(false)
                }
            }
        }
        // Width is controlled by ContentView via settingsManager.settings.sidebarWidth
        .onChange(of: sessionManager.sessions.count) { _, newCount in
            // Update drag coordinator with new count
            dragCoordinator.totalSessionCount = newCount
            // Restart monitoring when sessions change
            statusLineService.startMonitoring(sessions: sessionManager.sessions)
        }
        .onAppear {
            // Configure drag coordinator
            dragCoordinator.rowHeight = rowHeight
            dragCoordinator.totalSessionCount = sessionManager.sessions.count
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
