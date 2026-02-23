import SwiftUI

/// Shared status dot used in both expanded and collapsed sidebar rows.
/// Renders a colored circle that pulses opacity when the session is busy.
///
/// Colors: green (running), red (stopped), yellow (starting)
/// Pulse: 0.6s easeInOut, repeating with autoreverses when busy
struct SessionStatusDot: View {
    @ObservedObject var session: Session

    @State private var isPulsePhase = false

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .opacity(isPulsePhase ? 0.3 : 1.0)
            .onChange(of: session.isBusy) { _, newValue in
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
            return .red
        } else if session.isRunning {
            return .green
        } else {
            return .yellow
        }
    }
}
