import SwiftUI

/// ViewModifier that auto-clears a session's unread bell indicator
/// when the session is selected, the window is focused, and the
/// terminal tab is active. All three conditions must be met — viewing
/// the Ledger or Snapshots tab keeps the indicator visible.
struct BellIndicatorBehavior: ViewModifier {
    @ObservedObject var session: Session
    let isSelected: Bool
    let isWindowFocused: Bool
    let isOnTerminalTab: Bool

    private var shouldClear: Bool {
        isSelected && isWindowFocused && isOnTerminalTab && session.hasUnreadBell
    }

    private func clearIfNeeded() {
        if shouldClear {
            withAnimation(.easeOut(duration: 3.0)) {
                session.hasUnreadBell = false
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: isSelected) { _, _ in clearIfNeeded() }
            .onChange(of: isWindowFocused) { _, _ in clearIfNeeded() }
            .onChange(of: isOnTerminalTab) { _, _ in clearIfNeeded() }
            .onChange(of: session.hasUnreadBell) { _, newValue in
                if newValue && isSelected && isWindowFocused && isOnTerminalTab {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        clearIfNeeded()
                    }
                }
            }
    }
}

extension View {
    /// Apply bell indicator auto-clear behavior.
    func bellIndicatorBehavior(
        session: Session,
        isSelected: Bool,
        isWindowFocused: Bool,
        isOnTerminalTab: Bool
    ) -> some View {
        modifier(BellIndicatorBehavior(
            session: session,
            isSelected: isSelected,
            isWindowFocused: isWindowFocused,
            isOnTerminalTab: isOnTerminalTab
        ))
    }
}
