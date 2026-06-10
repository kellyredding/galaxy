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
        // DIAGNOSTIC (unread red-dot flakiness): only log when a dot is
        // actually present at trigger time — that's the only case relevant
        // to a stuck dot, and it keeps routine focus/tab/selection churn
        // out of the log. Remove once resolved.
        if session.hasUnreadResponse {
            GalaxyLog.dbg(
                "unread",
                "CLEAR-B \(session.diagnosticTag) surface=\(surface)"
                    + " trigger=\(trigger) cleared=\(did)"
                    + " sel=\(isSelected) focus=\(isWindowFocused)"
                    + " tab=\(isOnTerminalTab)"
            )
        }
        if did {
            session.hasUnreadResponse = false
            SessionManager.shared.updateDockBadge()
        }
    }

    func body(content: Content) -> some View {
        content
            .onAppear { clearIfNeeded("onAppear") }
            .onDisappear {
                // DIAGNOSTIC (unread red-dot flakiness): a dot-bearing row
                // unmounting (scrolled out of a lazy container, identity
                // churn) means its focus/tab onChange clears can no longer
                // fire — the prime suspect for a stuck dot. Remove once
                // resolved.
                if session.hasUnreadResponse {
                    GalaxyLog.dbg(
                        "unread",
                        "CLEAR-B \(session.diagnosticTag) surface=\(surface)"
                            + " UNMOUNT-while-unread"
                            + " sel=\(isSelected) focus=\(isWindowFocused)"
                            + " tab=\(isOnTerminalTab)"
                    )
                }
            }
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
                if newValue && isSelected && isWindowFocused && isOnTerminalTab {
                    // DIAGNOSTIC (unread red-dot flakiness): set while
                    // viewing — schedule the 0.1s re-check and log both the
                    // scheduling and (inside clearIfNeeded) the result.
                    GalaxyLog.dbg(
                        "unread",
                        "CLEAR-B \(session.diagnosticTag) surface=\(surface)"
                            + " trigger=unread->true scheduling 0.1s recheck"
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        clearIfNeeded("delayed-recheck")
                    }
                } else if newValue {
                    GalaxyLog.dbg(
                        "unread",
                        "CLEAR-B \(session.diagnosticTag) surface=\(surface)"
                            + " trigger=unread->true no-recheck"
                            + " sel=\(isSelected) focus=\(isWindowFocused)"
                            + " tab=\(isOnTerminalTab)"
                    )
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
