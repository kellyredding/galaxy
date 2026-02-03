import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsManager = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settingsManager.settings.themePreference) {
                    ForEach(ThemePreference.allCases, id: \.self) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.segmented)

                Text("Controls the Galaxy app appearance. Claude Code uses its own theme settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Theme")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 150)
        .navigationTitle("Settings")
    }
}
