import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsManager = SettingsManager.shared
    @State private var fontSizeText: String = ""

    var body: some View {
        VStack(spacing: 16) {
            // Layout section
            SettingsCard(title: "Layout") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Sessions panel") {
                        Picker("", selection: $settingsManager.settings.sidebarPosition) {
                            ForEach(SidebarPosition.allCases, id: \.self) { position in
                                Text(position.displayName).tag(position)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    SettingsRow(label: "Theme") {
                        Picker("", selection: $settingsManager.settings.themePreference) {
                            ForEach(ThemePreference.allCases, id: \.self) { preference in
                                Label(preference.displayName, systemImage: preference.iconName)
                                    .tag(preference)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
            }

            // Terminal section
            SettingsCard(title: "Terminal") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Font") {
                        Picker("", selection: $settingsManager.settings.terminalFontFamily) {
                            ForEach(Self.monospacedFontFamilies, id: \.self) { family in
                                Text(family)
                                    .font(.custom(family, size: 13))
                                    .tag(family)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    SettingsRow(label: "Default font size") {
                        HStack(spacing: 4) {
                            TextField("", text: $fontSizeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .multilineTextAlignment(.trailing)
                                .onAppear {
                                    fontSizeText = "\(Int(settingsManager.settings.defaultTerminalFontSize))"
                                }
                                .onChange(of: fontSizeText) { _, newValue in
                                    if let value = Double(newValue) {
                                        let clamped = min(max(value, AppSettings.terminalFontSizeRange.lowerBound),
                                                         AppSettings.terminalFontSizeRange.upperBound)
                                        settingsManager.settings.defaultTerminalFontSize = clamped
                                    }
                                }
                                .onChange(of: settingsManager.settings.defaultTerminalFontSize) { _, newValue in
                                    let newText = "\(Int(newValue))"
                                    if fontSizeText != newText {
                                        fontSizeText = newText
                                    }
                                }

                            Stepper("", value: $settingsManager.settings.defaultTerminalFontSize,
                                   in: AppSettings.terminalFontSizeRange,
                                   step: AppSettings.terminalFontSizeStep)
                                .labelsHidden()

                            Text("pt")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // Notifications section
            SettingsCard(title: "Notifications") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Terminal bell") {
                        HStack(spacing: 8) {
                            Picker("", selection: $settingsManager.settings.bellPreference) {
                                Text(BellPreference.system.displayName).tag(BellPreference.system)
                                Text(BellPreference.visualBell.displayName).tag(BellPreference.visualBell)
                                Text(BellPreference.none.displayName).tag(BellPreference.none)

                                Divider()

                                ForEach(BellPreference.allCases.filter { $0.isSound }, id: \.self) { pref in
                                    Text(pref.displayName).tag(pref)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)

                            Button(action: previewBell) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Preview bell sound")
                        }
                    }

                    HStack {
                        Toggle("Show unread indicator", isOn: $settingsManager.settings.showBellBadge)
                            .toggleStyle(.checkbox)
                        Spacer()
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 340)
        .fixedSize()
    }

    private func previewBell() {
        settingsManager.handleBell()
    }

    /// CJK font families that report as fixed-pitch but aren't suitable for terminal display
    private static let cjkFontFamilies: Set<String> = [
        "Lantinghei TC", "Lantinghei SC", "PCMyungjo",
        "Osaka", "Osaka−等幅",
    ]

    /// All monospaced font families suitable for terminal display, sorted alphabetically.
    /// Includes SF Mono (the system monospaced font) which requires special API access.
    private static let monospacedFontFamilies: [String] = {
        let fontManager = NSFontManager.shared

        var families = fontManager.availableFontFamilies.filter { family in
            guard !cjkFontFamilies.contains(family) else { return false }
            guard let members = fontManager.availableMembers(ofFontFamily: family),
                  let firstMember = members.first,
                  let postscriptName = firstMember[0] as? String,
                  let font = NSFont(name: postscriptName, size: 13.0) else {
                return false
            }
            return font.isFixedPitch
        }

        // SF Mono is the system monospaced font — only available via monospacedSystemFont(),
        // not through NSFontManager enumeration or NSFont(name:size:)
        families.append("SF Mono")

        return families.sorted()
    }()
}

// MARK: - Supporting Views

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.leading, 12)
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 0) {
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            content
        }
    }
}
