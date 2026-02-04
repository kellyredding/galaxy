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

            Section {
                Picker("Terminal Bell", selection: $settingsManager.settings.bellPreference) {
                    Text(BellPreference.system.displayName).tag(BellPreference.system)
                    Text(BellPreference.visualBell.displayName).tag(BellPreference.visualBell)
                    Text(BellPreference.none.displayName).tag(BellPreference.none)

                    Divider()

                    ForEach(BellPreference.allCases.filter { $0.isSound }, id: \.self) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }

                HStack {
                    Text("Plays when Claude Code needs your attention.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Preview") {
                        previewBell()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Toggle("Show unread indicator", isOn: $settingsManager.settings.showBellBadge)
            } header: {
                Text("Bell")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 450, minHeight: 250)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func previewBell() {
        settingsManager.handleBell()
    }
}
