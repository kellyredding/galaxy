import SwiftUI

/// ViewModifier that auto-clears a session's unread response indicator
/// when the session is selected, the window is focused, and the
/// terminal tab is active. All three conditions must be met — viewing
/// the Ledger or Snapshots tab keeps the indicator visible.
struct UnreadIndicatorBehavior: ViewModifier {
    @ObservedObject var session: Session
    let isSelected: Bool
    let isWindowFocused: Bool
    let isOnTerminalTab: Bool

    private var shouldClear: Bool {
        isSelected && isWindowFocused && isOnTerminalTab && session.hasUnreadResponse
    }

    private func clearIfNeeded() {
        if shouldClear {
            session.hasUnreadResponse = false
            SessionManager.shared.updateDockBadge()
        }
    }

    func body(content: Content) -> some View {
        content
            .onAppear { clearIfNeeded() }
            .onChange(of: isSelected) { _, _ in clearIfNeeded() }
            .onChange(of: isWindowFocused) { _, _ in clearIfNeeded() }
            .onChange(of: isOnTerminalTab) { _, _ in clearIfNeeded() }
            .onChange(of: session.hasUnreadResponse) { _, newValue in
                if newValue && isSelected && isWindowFocused && isOnTerminalTab {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        clearIfNeeded()
                    }
                }
            }
    }
}

extension View {
    /// Apply unread indicator auto-clear behavior.
    func unreadIndicatorBehavior(
        session: Session,
        isSelected: Bool,
        isWindowFocused: Bool,
        isOnTerminalTab: Bool
    ) -> some View {
        modifier(UnreadIndicatorBehavior(
            session: session,
            isSelected: isSelected,
            isWindowFocused: isWindowFocused,
            isOnTerminalTab: isOnTerminalTab
        ))
    }
}
