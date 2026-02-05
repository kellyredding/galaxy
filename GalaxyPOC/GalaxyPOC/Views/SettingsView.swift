import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsManager = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                Picker("Sessions Panel", selection: $settingsManager.settings.sidebarPosition) {
                    ForEach(SidebarPosition.allCases, id: \.self) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .pickerStyle(.segmented)

                Text("Position of the sessions list panel.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Layout")
            }

            Section {
                Picker("Appearance", selection: $settingsManager.settings.themePreference) {
                    ForEach(ThemePreference.allCases, id: \.self) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.segmented)

                Text("Controls the app appearance. Claude Code uses its own theme settings.")
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

            Section {
                HStack {
                    Text("Default terminal font size")
                    Spacer()
                    Stepper(
                        value: $settingsManager.settings.defaultTerminalFontSize,
                        in: AppSettings.terminalFontSizeRange,
                        step: AppSettings.terminalFontSizeStep
                    ) {
                        Text("\(Int(settingsManager.settings.defaultTerminalFontSize)) pt")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 50, alignment: .trailing)
                    }
                }

                Text("New sessions will start with this font size. Each session can be adjusted individually.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Terminal")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 450, minHeight: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func previewBell() {
        settingsManager.handleBell()
    }
}
