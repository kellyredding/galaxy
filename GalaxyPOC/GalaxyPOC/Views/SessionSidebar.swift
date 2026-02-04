import SwiftUI

struct SessionSidebar: View {
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject var statusLineService = StatusLineService.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sessionManager.sessions) { session in
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
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            sessionManager.switchTo(sessionId: session.id)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 220)
        .onChange(of: sessionManager.sessions.count) { _ in
            // Restart monitoring when sessions change
            statusLineService.startMonitoring(sessions: sessionManager.sessions)
        }
        .onAppear {
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
