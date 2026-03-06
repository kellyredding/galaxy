import SwiftUI

struct StoppedSessionView: View {
    @ObservedObject var session: Session
    var onResume: () -> Void

    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    var body: some View {
        ZStack {
            // Background with watermark
            Color(.textBackgroundColor)
            WatermarkBackground()

            // Content
            VStack(spacing: 20) {
                // Icon
                Image(systemName: "stop.circle")
                    .chromeFont(size: fontSize.iconXLarge)
                    .foregroundColor(.red.opacity(0.7))

                // Session info
                VStack(spacing: 8) {
                    Text("Session stopped")
                        .chromeFont(size: fontSize.title2, weight: .semibold)

                    Text(session.displayName)
                        .chromeFontMono(size: fontSize.title3)
                        .foregroundColor(.secondary)

                    if let exitCode = session.exitCode {
                        Text("Exit code: \(exitCode)")
                            .chromeFont(size: fontSize.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()
                    .frame(maxWidth: 400)

                // Resume instructions
                VStack(spacing: 12) {
                    Text("Resume this session")
                        .chromeFont(size: fontSize.headline, weight: .semibold)

                    // Resume button
                    Button(action: onResume) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Resume session")
                        }
                        .chromeFont(size: fontSize.body)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .focusable(false)

                    Text("or resume elsewhere:")
                        .chromeFont(size: fontSize.caption)
                        .foregroundColor(.secondary)

                    // CLI command with copy button
                    HStack(spacing: 8) {
                        Text(session.resumeCommand)
                            .chromeFontMono(size: fontSize.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        CopyButton(
                            text: session.resumeCommand,
                            iconSize: fontSize.iconSmall
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()  // Clip watermark to content area bounds
    }

}
