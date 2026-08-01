import Combine
import SwiftUI
import Galactic

/// SwiftUI container for the Shell pane. Lays out the
/// `ShellPaneBar` on top and the terminal below.
/// Instantiated by `TerminalTabSplitView` when the split is
/// open.
struct ShellPaneView: View {
    @ObservedObject var pane: ShellTerminalPane
    let isActiveSession: Bool
    let isVisibleSurface: Bool
    let onBarDragBegan: () -> Void
    let onBarDrag: (CGFloat) -> Void
    let onBarDragEnded: () -> Void
    let onBarDoubleClick: () -> Void

    /// What can stop the agent beside this shell being written to. The shell
    /// sends into that agent, so its own state is not the question.
    private var sendBlockerChanges: SendBlockerChanges {
        guard let session = pane.session else { return .never }
        return Publishers.CombineLatest(
            session.$isRunning, session.$hasExited
        )
        .map { _, _ in () }
        .eraseToAnyPublisher()
    }

    var body: some View {
        VStack(spacing: 0) {
            ShellPaneBar(
                onDragBegan: onBarDragBegan,
                onDrag: onBarDrag,
                onDragEnded: onBarDragEnded,
                onResetSplit: onBarDoubleClick
            )
            .frame(height: 28)

            // `.equatable()` opts into FocusableTerminalView's
            // Equatable conformance so SwiftUI skips
            // updateNSView on rows whose pane and activity
            // flags haven't changed.
            FocusableTerminalView(
                pane: pane,
                timelineRecorder: .galaxyLedger,
                settings: SettingsManager.shared,
                findActivations: SessionManager.shared.findActivations,
                // No turns happen in a shell, so there is nothing here to
                // interrupt. Answered with a value rather than by the host
                // working it out from what kind of pane this is.
                turnInterrupt: nil,
                paneRegistry: pane.session?.paneRegistry,
                // A shell's own exit does not close its scrollback today, and
                // this preserves that rather than deciding it here: `.never`
                // says the wiring is present and nothing will come through it.
                surfaceEndings: .never,
                sendBlockerChanges: sendBlockerChanges,
                isActiveSession: isActiveSession,
                isVisibleSurface: isVisibleSurface
            )
            .equatable()
        }
    }
}
