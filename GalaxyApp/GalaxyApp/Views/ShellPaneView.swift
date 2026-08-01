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
                isActiveSession: isActiveSession,
                isVisibleSurface: isVisibleSurface
            )
            .equatable()
        }
    }
}
