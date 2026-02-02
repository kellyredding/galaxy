import SwiftUI

struct SessionSidebar: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        List {
            Section("Sessions") {
                ForEach(sessionManager.sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: session.id == sessionManager.activeSessionId,
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
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { sessionManager.createSession() }) {
                    Image(systemName: "plus")
                }
                .help("New Session (⌘N)")
            }
        }
    }
}
