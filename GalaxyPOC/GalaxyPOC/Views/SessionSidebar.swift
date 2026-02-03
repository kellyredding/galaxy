import SwiftUI

struct SessionSidebar: View {
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject var statusLineService = StatusLineService.shared

    var body: some View {
        List {
            Section("Sessions") {
                ForEach(sessionManager.sessions) { session in
                    SessionRow(
                        session: session,
                        statusLineService: statusLineService,
                        isSelected: session.id == sessionManager.activeSessionId,
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
        .listStyle(.sidebar)
        .frame(minWidth: 220)  // Slightly wider to accommodate git status
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
