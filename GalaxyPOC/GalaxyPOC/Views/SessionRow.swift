import SwiftUI

struct SessionRow: View {
    @ObservedObject var session: Session
    @ObservedObject var statusLineService: StatusLineService
    let isSelected: Bool
    var onStop: () -> Void   // Stop a running session
    var onClose: () -> Void  // Remove a stopped session from list

    @State private var isHovered = false

    private var statusInfo: StatusLineService.SessionStatusInfo? {
        statusLineService.statusInfo[session.id]
    }

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                // User session ID (human-readable)
                Text(session.userSessionId)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundColor(isSelected ? .white : .primary)

                // Directory name + git status
                HStack(spacing: 4) {
                    Text(session.name)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)

                    if let info = statusInfo, !info.gitStatusDisplay.isEmpty {
                        Text(info.gitStatusDisplay)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(gitStatusColor(info: info, isSelected: isSelected))
                    }
                }
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }

            Spacer()

            // Hover button - different action based on session state
            if isHovered {
                if session.hasExited {
                    // Stopped session: show Close button to remove from list
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("Remove session")
                    .transition(.opacity)
                } else {
                    // Running session: show Stop button
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(isSelected ? .white.opacity(0.7) : .red.opacity(0.8))
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("Stop session")
                    .transition(.opacity)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var statusColor: Color {
        if session.hasExited {
            return .red  // Stopped sessions
        } else if session.isRunning {
            return .green
        } else {
            return .yellow
        }
    }

    private func gitStatusColor(info: StatusLineService.SessionStatusInfo, isSelected: Bool) -> Color {
        if isSelected {
            // Use slightly different shades when selected
            if info.isDirty { return .yellow }
            if info.hasStaged { return .green }
            return .white.opacity(0.8)
        } else {
            if info.isDirty { return .orange }
            if info.hasStaged { return .green }
            return .secondary
        }
    }
}
