import Galactic
import SwiftUI

/// Keeps a Files pane alive per session, the way the artifacts and snapshots
/// containers do.
///
/// **A `ZStack` with opacity, not a conditional.** The pane holds a web view and
/// a scroll position, so tearing it down on every session switch would rebuild
/// the reader and lose where a reader had got to. That is also why the pane is
/// told whether it is the surface in front rather than inferring it: a zero
/// alpha is not hidden, and `performKeyEquivalent` is offered to the whole
/// hierarchy before the menu bar.
struct FilesContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    private var model: GalaxyFilesModel { GalaxyFilesModel.shared }

    var body: some View {
        ZStack {
            ForEach(sessionManager.sessions) { session in
                let active = session.id == sessionManager.activeSessionId
                FilesPaneView(
                    surface: model.surface,
                    set: model.set(for: session),
                    // Both halves, composed once — the same predicate
                    // `ArtifactsView` spells for itself.
                    isVisibleSurface: active
                        && sessionManager.activeTab == .files,
                    findActivations: model.findActivations
                        .eraseToAnyPublisher(),
                    lineJumpActivations: model.lineJumpActivations
                        .eraseToAnyPublisher(),
                    searchActivations: model.searchActivations
                        .eraseToAnyPublisher(),
                    emptyHint: "Press ⌘T to open one."
                )
                .opacity(active ? 1 : 0)
                .allowsHitTesting(active)
                .onAppear { model.restoreIfNeeded(for: session) }
            }
        }
    }
}
