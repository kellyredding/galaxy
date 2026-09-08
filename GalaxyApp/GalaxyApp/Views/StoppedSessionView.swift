import SwiftUI

struct StoppedSessionView: View {
    @ObservedObject var session: Session
    let isVisibleSurface: Bool
    var onResume: () -> Void

    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    /// Width of the resume command box, so the activity panel can line
    /// up with it. Zero until the first layout pass reports it.
    @State private var commandWidth: CGFloat = 0

    var body: some View {
        ZStack {
            // Background with watermark
            Color(.textBackgroundColor)
            WatermarkBackground()

            // Content.
            //
            // Scrollable, and centred only while it fits. This screen
            // used to be a fixed ~300pt of centred stack, but an
            // expanded history adds 320pt more than the pane has at the
            // 500pt window minimum. Pinning the content to at least the
            // viewport height keeps the collapsed screen centred
            // exactly as before and lets the expanded one scroll rather
            // than clip against `.clipped()` below.
            GeometryReader { geo in
                ScrollView {
                    content
                        .padding(.vertical, 20)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: geo.size.height
                        )
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()  // Clip watermark to content area bounds
    }

    private var content: some View {
        // Two stacks, at spacing 0 on the outside: the activity panel
        // draws nothing for a session with no recorded history, and a
        // spaced stack would still reserve a gap around the nothing,
        // shifting the centred block off where it has always sat.
        VStack(spacing: 0) {
            stoppedBlock

            StoppedSessionActivityPanel(
                session: session,
                isVisibleSurface: isVisibleSurface,
                width: commandWidth > 0 ? commandWidth : nil
            )
        }
        .onPreferenceChange(ResumeCommandWidthKey.self) { width in
            commandWidth = width
        }
    }

    private var stoppedBlock: some View {
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
                .background(
                    // Publishes this box's width so the activity panel
                    // below can match it. Measured rather than guessed
                    // because this box is sized by the resume command,
                    // which is as long as the working directory and
                    // session id make it.
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ResumeCommandWidthKey.self,
                            value: geo.size.width
                        )
                    }
                )
            }
        }
    }
}

/// The measured width of the resume command box.
private struct ResumeCommandWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(
        value: inout CGFloat, nextValue: () -> CGFloat
    ) {
        value = max(value, nextValue())
    }
}
