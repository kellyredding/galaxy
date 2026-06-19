import SwiftUI

/// ViewModifier that auto-clears a session's unread response indicator
/// when the session is selected, the window is focused, and the
/// terminal tab is active. All three conditions must be met — viewing
/// the Ledger or Snapshots tab keeps the indicator visible.
struct UnreadIndicatorBehavior: ViewModifier {
    @ObservedObject var session: Session
    /// Which rendering surface owns this modifier instance — purely for
    /// diagnostic logging (sidebar / collapsed / tab).
    let surface: String
    let isSelected: Bool
    let isWindowFocused: Bool
    let isOnTerminalTab: Bool

    private var shouldClear: Bool {
        isSelected && isWindowFocused && isOnTerminalTab && session.hasUnreadResponse
    }

    private func clearIfNeeded(_ trigger: String) {
        let did = shouldClear
        if did {
            session.hasUnreadResponse = false
            SessionManager.shared.updateDockBadge()
        }
    }

    func body(content: Content) -> some View {
        content
            .onAppear { clearIfNeeded("onAppear") }
            .onChange(of: isSelected) { _, newVal in
                clearIfNeeded("isSelected->\(newVal)")
            }
            .onChange(of: isWindowFocused) { _, newVal in
                clearIfNeeded("isWindowFocused->\(newVal)")
            }
            .onChange(of: isOnTerminalTab) { _, newVal in
                clearIfNeeded("isOnTerminalTab->\(newVal)")
            }
            .onChange(of: session.hasUnreadResponse) { _, newValue in
                // A dot set while this row is the focused, selected terminal
                // needs a deferred re-check: the set can land just after the
                // focus/selection state has settled, so re-run the clear on
                // the next tick to catch it.
                if newValue && isSelected && isWindowFocused && isOnTerminalTab {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        clearIfNeeded("delayed-recheck")
                    }
                }
            }
    }
}

extension View {
    /// Apply unread indicator auto-clear behavior.
    func unreadIndicatorBehavior(
        session: Session,
        surface: String,
        isSelected: Bool,
        isWindowFocused: Bool,
        isOnTerminalTab: Bool
    ) -> some View {
        modifier(UnreadIndicatorBehavior(
            session: session,
            surface: surface,
            isSelected: isSelected,
            isWindowFocused: isWindowFocused,
            isOnTerminalTab: isOnTerminalTab
        ))
    }
}
