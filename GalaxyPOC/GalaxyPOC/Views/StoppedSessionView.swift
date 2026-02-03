import SwiftUI
import AppKit

struct StoppedSessionView: View {
    @ObservedObject var session: Session
    var onResume: () -> Void

    @State private var showCopied = false

    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "stop.circle")
                .font(.system(size: 64))
                .foregroundColor(.red.opacity(0.7))

            // Session info
            VStack(spacing: 8) {
                Text("Session Stopped")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(session.userSessionId)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundColor(.secondary)

                if let exitCode = session.exitCode {
                    Text("Exit code: \(exitCode)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()
                .frame(maxWidth: 400)

            // Resume instructions
            VStack(spacing: 12) {
                Text("Resume this session")
                    .font(.headline)

                // Resume button
                Button(action: onResume) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Resume Session")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("or use the CLI:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // CLI command with copy button
                HStack(spacing: 8) {
                    Text(session.resumeCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button(action: copyCommand) {
                        Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(showCopied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy command to clipboard")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.windowBackgroundColor))
                .cornerRadius(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.textBackgroundColor))
    }

    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.resumeCommand, forType: .string)

        // Show copied feedback
        withAnimation {
            showCopied = true
        }

        // Reset after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopied = false
            }
        }
    }
}
