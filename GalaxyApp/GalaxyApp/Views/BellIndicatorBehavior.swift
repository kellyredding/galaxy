import SwiftUI

/// ViewModifier that auto-clears a session's unread bell indicator
/// when the session is selected and the window is focused.
/// Encapsulates the three onChange handlers that both expanded
/// SessionRow and collapsed CollapsedSessionRow need.
struct BellIndicatorBehavior: ViewModifier {
    @ObservedObject var session: Session
    let isSelected: Bool
    let isWindowFocused: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isSelected) { _, newValue in
                if newValue && isWindowFocused && session.hasUnreadBell {
                    withAnimation(.easeOut(duration: 3.0)) {
                        session.hasUnreadBell = false
                    }
                }
            }
            .onChange(of: isWindowFocused) { _, newValue in
                if newValue && isSelected && session.hasUnreadBell {
                    withAnimation(.easeOut(duration: 3.0)) {
                        session.hasUnreadBell = false
                    }
                }
            }
            .onChange(of: session.hasUnreadBell) { _, newValue in
                if newValue && isSelected && isWindowFocused {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 3.0)) {
                            session.hasUnreadBell = false
                        }
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
        isWindowFocused: Bool
    ) -> some View {
        modifier(BellIndicatorBehavior(
            session: session,
            isSelected: isSelected,
            isWindowFocused: isWindowFocused
        ))
    }
}
