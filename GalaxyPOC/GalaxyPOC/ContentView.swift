import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var settingsManager: SettingsManager

    private let sidebarWidth: CGFloat = 220
    private let toolbarHeight: CGFloat = 28

    private var isSidebarVisible: Bool {
        sessionManager.isSidebarVisible
    }

    /// The currently active session (for terminal font control)
    private var activeSession: Session? {
        guard let activeId = sessionManager.activeSessionId else { return nil }
        return sessionManager.sessions.first { $0.id == activeId }
    }

    private var sidebarOnLeft: Bool {
        settingsManager.settings.sidebarPosition == .left
    }

    var body: some View {
        VStack(spacing: 0) {
            // Control bar
            controlBar

            // Main content area
            HStack(spacing: 0) {
                if sidebarOnLeft {
                    sidebarSection
                    detailSection
                } else {
                    detailSection
                    sidebarSection
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            if sidebarOnLeft {
                sidebarToggleButton
                Spacer()
            } else {
                Spacer()
                sidebarToggleButton
            }
        }
        .padding(.horizontal, 8)
        .frame(height: toolbarHeight)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var sidebarToggleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                sessionManager.isSidebarVisible.toggle()
            }
        }) {
            Image(systemName: sidebarOnLeft ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 14))
                .foregroundColor(isSidebarVisible ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(isSidebarVisible ? "Hide Sessions" : "Show Sessions")
    }

    @ViewBuilder
    private var sidebarSection: some View {
        if isSidebarVisible {
            SessionSidebar()
                .frame(width: sidebarWidth)
                .transition(.move(edge: sidebarOnLeft ? .leading : .trailing))
        }
    }

    private var detailSection: some View {
        Group {
            if sessionManager.sessions.isEmpty {
                EmptyStateView()
            } else {
                TerminalContainerView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme

    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    /// Background color matching terminal emulator (black in dark, white in light)
    private var terminalBackground: Color {
        colorScheme == .dark ? .black : .white
    }

    /// Text color for contrast against terminal background
    private var terminalForeground: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .chromeFont(size: fontSize.iconLarge)
                .foregroundColor(.secondary)

            Text("No Sessions")
                .chromeFont(size: fontSize.title2)
                .foregroundColor(terminalForeground)

            Text("Run `galaxy` from any directory to start a session")
                .chromeFont(size: fontSize.body)
                .foregroundColor(.secondary)

            Text("cd ~/projects/my-app && galaxy")
                .chromeFontMono(size: fontSize.body)
                .padding(8)
                .background(Color(.windowBackgroundColor))
                .cornerRadius(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
    }
}
