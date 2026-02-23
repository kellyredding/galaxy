import SwiftUI

/// Bright red indicator dot shown when a session has an unread bell.
/// Parent views position this via offset or ZStack alignment.
/// Visibility is controlled by the parent based on session.hasUnreadBell
/// and the showBellBadge setting.
struct UnreadBellIndicator: View {
    var body: some View {
        Circle()
            .fill(Color(red: 1.0, green: 0.2, blue: 0.2))
            .frame(width: 8, height: 8)
            .shadow(
                color: Color.red.opacity(0.6),
                radius: 3,
                x: 0,
                y: 0
            )
    }
}
