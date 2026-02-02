import SwiftUI

struct SessionRow: View {
    @ObservedObject var session: Session
    let isSelected: Bool
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(.body, design: .default))
                    .lineLimit(1)
                    .foregroundColor(isSelected ? .white : .primary)

                Text(statusText)
                    .font(.caption)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }

            Spacer()

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Close session")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }

    private var statusColor: Color {
        if session.hasExited {
            return .gray
        } else if session.isRunning {
            return .green
        } else {
            return .yellow
        }
    }

    private var statusText: String {
        if session.hasExited {
            if let code = session.exitCode {
                return "Exited (\(code))"
            }
            return "Exited"
        } else if session.isRunning {
            return "Running"
        } else {
            return "Starting..."
        }
    }
}
