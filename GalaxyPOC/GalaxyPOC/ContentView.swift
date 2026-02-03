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
                SessionContentView(
                    session: session,
                    isActive: session.id == sessionManager.activeSessionId,
                    onResume: { sessionManager.resumeSession(sessionId: session.id) }
                )
            }
        }
    }
}

/// Wrapper view that observes individual session state changes
struct SessionContentView: View {
    @ObservedObject var session: Session
    let isActive: Bool
    let onResume: () -> Void

    var body: some View {
        Group {
            if session.hasExited {
                // Show stopped session UI
                StoppedSessionView(session: session, onResume: onResume)
            } else {
                // Show terminal
                FocusableTerminalView(
                    session: session,
                    isActive: isActive
                )
            }
        }
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
    }
}
