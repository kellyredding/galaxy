import Combine
import SwiftUI
import Galactic

/// Wrapper view that observes individual session state changes.
/// Constructs a SessionTerminalPane adapter for the running
/// branch, cached via a @StateObject so its identity is stable
/// across SwiftUI re-renders and only rebuilt when the underlying
/// backend changes (e.g., after a stop+resume cycle).
struct SessionPaneView: View {
    @ObservedObject var session: Session
    let isActiveSession: Bool
    let isVisibleSurface: Bool
    let onResume: () -> Void

    @StateObject private var adapterHolder = SessionPaneAdapterHolder()

    /// The moment this session ends, as the host needs to hear it.
    ///
    /// Deduplicated because the flag republishes, and mapped without a queue
    /// hop: it is already set on main, and this view is replaced in the same
    /// turn it flips — a hop would arrive after the overlay that needed
    /// closing had gone.
    private var surfaceEndings: SurfaceEndings {
        session.$hasExited
            .removeDuplicates()
            .filter { $0 }
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// What can stop this session being written to.
    private var sendBlockerChanges: SendBlockerChanges {
        Publishers.CombineLatest(session.$isRunning, session.$hasExited)
            .map { _, _ in () }
            .eraseToAnyPublisher()
    }

    /// Recording an interrupted turn, for the surface a turn happens on.
    ///
    /// Weakly held on purpose: a session that has gone away has no turn left to
    /// interrupt, so there is nothing here worth keeping it alive for.
    /// Idempotency is the recorder's — leaning on Esc against one turn reads
    /// its state as already cleared and stops there.
    private var turnInterrupt: TurnInterrupt {
        let session = session
        return TurnInterrupt(
            isInTurn: { [weak session] in session?.isInTurn ?? false },
            record: { [weak session] in
                guard let session else { return }
                SessionManager.shared.recordEscapeInterrupt(for: session)
            }
        )
    }

    var body: some View {
        Group {
            if session.hasExited {
                // Show stopped session UI
                StoppedSessionView(session: session, onResume: onResume)
            } else if let backend = session.backend {
                // Show terminal via TerminalPane abstraction.
                // `.equatable()` opts into our Equatable
                // conformance for SwiftUI's diff, guaranteeing
                // updateNSView is skipped on rows whose pane
                // and activity flags haven't changed.
                FocusableTerminalView(
                    pane: adapterHolder.adapter(
                        for: session, backend: backend
                    ),
                    timelineRecorder: .galaxyLedger,
                    settings: SettingsManager.shared,
                    findActivations: SessionManager.shared.findActivations,
                    scrollbackActivations:
                        MenuActions.scrollbackActivations,
                    turnInterrupt: turnInterrupt,
                    paneRegistry: session.paneRegistry,
                    surfaceEndings: surfaceEndings,
                    sendBlockerChanges: sendBlockerChanges,
                    isActiveSession: isActiveSession,
                    isVisibleSurface: isVisibleSurface,
                    // This app hides a pane whose session is not selected, so
                    // the moment to give up the caret is the deselection —
                    // before the hide, not when the user merely moves to
                    // another tab with this session still showing behind it.
                    shouldResignFocus: !isActiveSession
                )
                .equatable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: session.hasExited) {
            // Release the cached adapter (and its strong reference
            // to the old backend) when the session stops. Without
            // this, the ~32MB scrollback buffer stays resident
            // until the user either resumes the session (which
            // replaces the cached adapter) or dismisses it (which
            // tears down the whole SessionPaneView). With it,
            // Session.releaseBackend can actually free the buffer
            // at stop time, matching pre-refactor behavior.
            if session.hasExited {
                adapterHolder.release()
            }
        }
    }
}

/// Caches a SessionTerminalPane adapter per SessionPaneView
/// lifetime, returning the same instance for the same underlying
/// backend. On backend change (e.g., stop+resume creates a fresh
/// backend), a new adapter is constructed.
///
/// The cached adapter is stored in a non-@Published property so
/// mutating it during body evaluation doesn't re-trigger SwiftUI
/// updates.
private final class SessionPaneAdapterHolder: ObservableObject {
    private var cached: SessionTerminalPane?

    func adapter(
        for session: Session,
        backend: TerminalBackend
    ) -> SessionTerminalPane {
        if let cached, cached.backend === backend {
            return cached
        }
        let fresh = SessionTerminalPane(
            session: session, backend: backend
        )
        cached = fresh
        return fresh
    }

    /// Drop the cached adapter so the backend it holds strongly
    /// can be released. Called when the session stops so the
    /// scrollback buffer is freed at stop time rather than at
    /// resume or dismiss time.
    func release() {
        cached = nil
    }
}
