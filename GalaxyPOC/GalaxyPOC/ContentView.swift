import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        NavigationSplitView {
            SessionSidebar()
        } detail: {
            if sessionManager.sessions.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("No Sessions")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Press ⌘N to create a new Claude session")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("New Session") {
                        sessionManager.createSession()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TerminalContainerView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 500)
    }
}

struct TerminalContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        ZStack {
            ForEach(sessionManager.sessions) { session in
                FocusableTerminalView(
                    session: session,
                    isActive: session.id == sessionManager.activeSessionId
                )
                .opacity(session.id == sessionManager.activeSessionId ? 1 : 0)
                .allowsHitTesting(session.id == sessionManager.activeSessionId)
            }
        }
    }
}
