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
            .animation(pulseAnimation, value: isPulsePhase)
            .onChange(of: session.isInTurn) { _, newValue in
                isPulsePhase = newValue
            }
    }

    /// The pulse curve, scoped to this view rather than handed to
    /// `withAnimation`.
    ///
    /// `withAnimation` puts its curve on the transaction and not on a
    /// view, so every animatable change committed in the same update
    /// pass inherits it — and a `repeatForever` curve inherited by a
    /// *frame* never ends, because there is no completion to return it
    /// to rest. A sibling row's `ViewThatFits` measuring its CWD line in
    /// the pass where some session began a turn would then slide back
    /// and forth on this 0.6s autoreversing cycle for the life of the
    /// window, and rows joined that state one at a time for as long as
    /// the app stayed up. Scoped here, the curve reaches nothing but
    /// this circle's opacity.
    ///
    /// The same shape the refresh spinners in `ArtifactsView` and
    /// `SnapshotsView` already use, which repeat forever without
    /// leaking for exactly this reason.
    private var pulseAnimation: Animation {
        session.isInTurn
            ? .easeInOut(duration: 0.6)
                .repeatForever(autoreverses: true)
            : .easeInOut(duration: 0.3)
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
                // Sized to the number, not to what the dot offers.
                //
                // Both sidebars hang this off an 8-point status dot as an
                // overlay, and an overlay is proposed its host's size — eight
                // points, which one bold monospaced digit fits and two do not.
                // So the count read correctly until a tenth agent started and
                // then became an ellipsis, which is the only thing that fits.
                //
                // The offset is what hides it: it draws the badge clear of the
                // dot, so nothing looks constrained, but an offset is applied
                // after layout and never widens what the text was offered.
                .fixedSize()
                .offset(x: 6, y: -12)
        }
    }
}
