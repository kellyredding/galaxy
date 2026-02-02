import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        NavigationSplitView {
            SessionSidebar()
        } detail: {
            if sessionManager.sessions.isEmpty {
                EmptyStateView()
            } else {
                TerminalContainerView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 500)
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Sessions")
                .font(.title2)

            Text("Run `galaxy` from any directory to start a session")
                .foregroundColor(.secondary)

            Text("cd ~/projects/my-app && galaxy")
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color(.windowBackgroundColor))
                .cornerRadius(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
