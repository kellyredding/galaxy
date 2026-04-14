import SwiftUI

/// Shared status dot used in both expanded and collapsed sidebar rows.
/// Renders a colored circle that pulses opacity when the session is busy.
///
/// Colors: green (alive), gray (stopped)
/// Pulse: 0.6s easeInOut, repeating with autoreverses when busy
struct SessionStatusDot: View {
    @ObservedObject var session: Session

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPulsePhase = false

    /// Theme-adaptive stroke to define the dot edge against light backgrounds
    private var strokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.25)
            : Color.black.opacity(0.3)
    }

    var body: some View {
        Circle()
            .fill(statusColor)
            .overlay(
                Circle()
                    .stroke(strokeColor, lineWidth: 0.5)
            )
            .frame(width: 8, height: 8)
            .opacity(isPulsePhase ? 0.3 : 1.0)
            .onChange(of: session.isInTurn) { _, newValue in
                if newValue {
                    withAnimation(
                        .easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true)
                    ) {
                        isPulsePhase = true
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isPulsePhase = false
                    }
                }
            }
    }

    private var statusColor: Color {
        if session.hasExited {
            return .secondary
        } else {
            return .green
        }
    }
}

/// Lightweight superscript showing the running agent count.
/// Accepts a plain Int so it doesn't carry an @ObservedObject —
/// the parent view is responsible for observing session state.
struct AgentCountSuperscript: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(
                    .system(
                        size: 12,
                        weight: .bold,
                        design: .monospaced
                    )
                )
                .foregroundColor(.green)
                .offset(x: 6, y: -12)
        }
    }
}
