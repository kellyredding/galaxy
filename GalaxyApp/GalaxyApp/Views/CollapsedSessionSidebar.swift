import SwiftUI

/// Collapsed session sidebar — compact counterpart to ExpandedSessionSidebar.
/// Shows one status dot per session. Visible when sidebar is collapsed,
/// providing at-a-glance session status without occupying full sidebar width.
struct CollapsedSessionSidebar: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sessionManager.sessions) { session in
                    CollapsedSessionRow(
                        session: session,
                        isSelected: session.id == sessionManager.activeSessionId,
                        isWindowFocused: sessionManager.isWindowFocused
                    )
                    .onTapGesture {
                        sessionManager.switchTo(sessionId: session.id)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// A single row in the collapsed session sidebar.
/// Shows the status dot centered in a row that matches the expanded
/// sidebar row height, plus unread bell indicator (top-right) and
/// visual bell flash overlay on the full row area.
struct CollapsedSessionRow: View {
    @ObservedObject var session: Session
    let isSelected: Bool
    let isWindowFocused: Bool

    @Environment(\.chromeFontSize) private var chromeFontSize

    /// Match expanded SessionRow height: top(6) + caption2Line + 2 + tinyLine + 2 + tinyLine + bottom(7)
    private var rowHeight: CGFloat {
        let fs = ChromeFontSize(chromeFontSize)
        return 17 + fs.caption2LineHeight + 2 * fs.tinyLineHeight
    }

    var body: some View {
        ZStack {
            // Selection background
            Rectangle()
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.25)
                        : Color.clear
                )

            // Visual bell flash overlay (entire row area)
            if isSelected && session.visualBellActive {
                Rectangle()
                    .fill(Color.white.opacity(0.4))
            }

            // Status dot
            SessionStatusDot(session: session)
        }
        .frame(width: 32, height: rowHeight)
        .overlay(alignment: .topTrailing) {
            // Unread bell indicator — top-right of the row
            if session.hasUnreadBell {
                UnreadBellIndicator()
                    .offset(x: 0, y: 6)
            }
        }
        .overlay(alignment: .bottom) {
            // Row separator (matches expanded sidebar)
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .help(session.displayName)
        .animation(.easeInOut(duration: 0.08), value: session.visualBellActive)
        .bellIndicatorBehavior(
            session: session,
            isSelected: isSelected,
            isWindowFocused: isWindowFocused
        )
    }
}
