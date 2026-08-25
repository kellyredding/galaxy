import Galactic
import SwiftUI

/// Settings for the Files surface: how much of a file a search result shows,
/// and the index the picker searches.
///
/// **Both cards come from the package**, for two different reasons. The index
/// belongs to no application — it is one set of files under `~/.galactic` shared
/// by every app on the machine — so what it holds and which folders it skips are
/// not this app's settings to own. The search card is shared the other way
/// round: the *value* is this app's, because how much of a file a reader is
/// shown is a preference two applications may answer differently, but the label,
/// the range and the stepper never were.
///
/// They will not match the cards on the neighbouring tabs. This app declares its
/// own `SettingsCard` and `SettingsRow`, which shadow the package's for its own
/// call sites — but these two views build their cards inside the package, where
/// the shadowing does not reach.
struct FilesSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
            FilesSettingsView(
                searchContextLines: $settingsManager.settings
                    .fileSearchContextLines
            )
            FileIndexSettingsView()
        }
        .padding(16)
    }
}
