import SwiftUI
import UserNotifications

// MARK: - Settings Tab Definition

enum SettingsTab: String, CaseIterable {
    case general
    case sessions
    case terminal
    case alerts

    var title: String {
        switch self {
        case .general: return "General"
        case .sessions: return "Sessions"
        case .terminal: return "Terminal"
        case .alerts: return "Alerts"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .sessions: return "text.bubble"
        case .terminal: return "apple.terminal"
        case .alerts: return "bell"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsManager = SettingsManager.shared
    @State private var fontSizeText: String = ""
    @State private var scrollbackText: String = ""
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // Icon tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsTabButton(tab: tab, isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsTab(settingsManager: settingsManager)
                case .sessions:
                    SessionsSettingsTab(settingsManager: settingsManager)
                case .terminal:
                    TerminalSettingsTab(
                        settingsManager: settingsManager,
                        fontSizeText: $fontSizeText,
                        scrollbackText: $scrollbackText
                    )
                case .alerts:
                    AlertsSettingsTab(settingsManager: settingsManager)
                }
            }
        }
        .frame(width: 420)
    }
}

struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(tab.title)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        )
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
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

            Spacer()
        }
        .padding(20)
    }
}

// MARK: - Sessions Tab

struct SessionsSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "New session") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default start directory")
                    DirectoryField(text: $settingsManager.settings.newSessionDefaultDir)
                }
            }

            SettingsCard(title: "Git status") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Style") {
                        Picker("", selection: $settingsManager.settings.gitStatusStyle) {
                            ForEach(GitStatusStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    GitStatusPreviewView(
                        style: settingsManager.settings.gitStatusStyle
                    )
                }
            }

            SettingsCard(title: "Auto-clear") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Toggle("Auto-clear at high context usage", isOn: $settingsManager.settings.autoClearEnabled)
                            .toggleStyle(.checkbox)
                        Spacer()
                    }

                    if settingsManager.settings.autoClearEnabled {
                        SettingsRow(label: "Context threshold") {
                            HStack(spacing: 4) {
                                Stepper(
                                    "\(settingsManager.settings.autoClearThreshold)%",
                                    value: $settingsManager.settings.autoClearThreshold,
                                    in: AppSettings.autoClearThresholdRange
                                )
                                .frame(width: 100)
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(20)
    }
}

// MARK: - Git Status Preview

struct GitStatusPreviewView: View {
    let style: GitStatusStyle

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    // Match SessionRow color definitions (deep saturated for light, bright for dark)
    private var cwdColor: Color {
        isDark ? .yellow : Color(red: 0.75, green: 0.5, blue: 0.0)
    }
    private var branchColor: Color {
        isDark ? .green : Color(red: 0.0, green: 0.55, blue: 0.15)
    }
    private var stashColor: Color {
        isDark ? .red : Color(red: 0.8, green: 0.1, blue: 0.1)
    }
    private var upstreamColor: Color {
        isDark ? .cyan : Color(red: 0.0, green: 0.5, blue: 0.7)
    }
    private var bracketColor: Color { .secondary }

    var body: some View {
        let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
        let monoBold = Font.system(size: 11, weight: .bold, design: .monospaced)

        HStack(spacing: 0) {
            // Fabricated CWD
            Text("~/p/app")
                .font(monoBold)
                .foregroundColor(cwdColor)

            Text("[").font(mono).foregroundColor(bracketColor)
            Text("main").font(monoBold).foregroundColor(branchColor)

            switch style {
            case .symbolic:
                Text("^").font(mono).foregroundColor(stashColor)
                Text("<>").font(monoBold).foregroundColor(upstreamColor)
                Text("+").font(mono).foregroundColor(branchColor)
                Text("*").font(mono).foregroundColor(cwdColor)

            case .arrows:
                Text("^").font(mono).foregroundColor(stashColor)
                Text("↓1").font(monoBold).foregroundColor(upstreamColor)
                Text("↑2").font(monoBold).foregroundColor(upstreamColor)
                Text("+").font(mono).foregroundColor(branchColor)
                Text("*").font(mono).foregroundColor(cwdColor)

            case .minimal:
                Text("*").font(mono).foregroundColor(cwdColor)
            }

            Text("]").font(mono).foregroundColor(bracketColor)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}

// MARK: - Terminal Tab

struct TerminalSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager
    @Binding var fontSizeText: String
    @Binding var scrollbackText: String

    /// Format an integer with comma grouping (e.g. 10000 → "10,000")
    private static func formatWithCommas(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Parse a comma-formatted string to an integer (e.g. "10,000" → 10000)
    private static func parseCommaNumber(_ text: String) -> Int? {
        let stripped = text.replacingOccurrences(of: ",", with: "")
        return Int(stripped)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Font settings
            SettingsCard(title: "Font") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Family") {
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

                    SettingsRow(label: "Default size") {
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

            // Scrollback settings
            SettingsCard(title: "Scrollback") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "History size") {
                        HStack(spacing: 4) {
                            TextField("", text: $scrollbackText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .onAppear {
                                    scrollbackText = Self.formatWithCommas(
                                        settingsManager.settings.terminalScrollbackLines
                                    )
                                }
                                .onChange(of: scrollbackText) { _, newValue in
                                    if let value = Self.parseCommaNumber(newValue) {
                                        let clamped = min(
                                            max(value, AppSettings.terminalScrollbackRange.lowerBound),
                                            AppSettings.terminalScrollbackRange.upperBound
                                        )
                                        settingsManager.settings.terminalScrollbackLines = clamped
                                    }
                                }
                                .onChange(of: settingsManager.settings.terminalScrollbackLines) { _, newValue in
                                    let newText = Self.formatWithCommas(newValue)
                                    if scrollbackText != newText {
                                        scrollbackText = newText
                                    }
                                }

                            Text("lines")
                                .foregroundColor(.secondary)
                        }
                    }

                    ScrollbackMemoryReferenceView()
                }
            }

            // Color theme settings
            SettingsCard(title: "Colors") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Theme") {
                        Picker("", selection: $settingsManager.settings.terminalColorThemeName) {
                            ForEach(TerminalColorTheme.builtIn) { theme in
                                Text(theme.name).tag(theme.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    ThemePreviewView(
                        theme: TerminalColorTheme.theme(
                            named: settingsManager.settings.terminalColorThemeName
                        )
                    )
                }
            }

            Spacer()
        }
        .padding(20)
    }

    /// CJK font families that report as fixed-pitch but aren't suitable for terminal display
    private static let cjkFontFamilies: Set<String> = [
        "Lantinghei TC", "Lantinghei SC", "PCMyungjo",
        "Osaka", "Osaka\u{2212}\u{7B49}\u{5E45}",
    ]

    /// All monospaced font families suitable for terminal display, sorted alphabetically.
    /// Includes SF Mono (the system monospaced font) which requires special API access.
    static let monospacedFontFamilies: [String] = {
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

// MARK: - Alerts Tab

struct AlertsSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var badgeAuthStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(spacing: 16) {
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

                            Button(action: { settingsManager.handleBell() }) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Preview bell sound")
                        }
                    }

                    HStack {
                        Toggle("Show unread indicator", isOn: $settingsManager.settings.showUnreadIndicator)
                            .toggleStyle(.checkbox)
                        Spacer()
                    }

                    // Dock badge toggle with authorization status
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle("Show dock badge", isOn: $settingsManager.settings.showDockBadge)
                                .toggleStyle(.checkbox)
                                .onChange(of: settingsManager.settings.showDockBadge) { _, enabled in
                                    if enabled {
                                        Task {
                                            let granted = await settingsManager.requestBadgeAuthorization()
                                            badgeAuthStatus = granted ? .authorized : .denied
                                            // Update badge immediately with current unread count
                                            SessionManager.shared.updateDockBadge()
                                        }
                                    } else {
                                        // Clear badge immediately when disabled
                                        NSApp.dockTile.badgeLabel = nil
                                    }
                                }
                            Spacer()
                        }

                        // Show authorization warning when enabled but denied.
                        // Note: this only detects denial of the initial permission
                        // prompt. The per-app "Badge app icon" toggle in System
                        // Settings is not queryable via any API — a platform
                        // limitation shared by all Mac apps.
                        if settingsManager.settings.showDockBadge && badgeAuthStatus == .denied {
                            HStack(spacing: 4) {
                                Text("Badge disabled in system settings.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Button("Open Notification Settings") {
                                    settingsManager.openNotificationSettings()
                                }
                                .font(.system(size: 11))
                                .buttonStyle(.link)
                            }
                            .padding(.leading, 20)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .task {
            // Check authorization status on appear (no prompt)
            await refreshBadgeAuthStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Refresh auth status when window regains focus (user may have
            // changed notification settings in System Settings and returned)
            Task {
                await refreshBadgeAuthStatus()
            }
        }
    }

    private func refreshBadgeAuthStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        badgeAuthStatus = settings.authorizationStatus
    }
}

// MARK: - Scrollback Memory Reference

struct ScrollbackMemoryReferenceView: View {
    private static let numberFormatter: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.groupingSeparator = ","
        fmt.usesGroupingSeparator = true
        return fmt
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack {
                Text("Lines")
                    .frame(width: 80, alignment: .trailing)
                Spacer()
                Text("Est. memory")
                    .frame(width: 100, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)

            Divider()

            // Data rows
            ForEach(AppSettings.scrollbackMemoryTiers, id: \.lines) { tier in
                HStack {
                    Text(Self.numberFormatter.string(from: NSNumber(value: tier.lines)) ?? "\(tier.lines)")
                        .frame(width: 80, alignment: .trailing)
                    Spacer()
                    Text(tier.memory)
                        .frame(width: 100, alignment: .trailing)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            }

            // Footnote
            Text("Based on 200-column terminal width")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}

// MARK: - Theme Preview

struct ThemePreviewView: View {
    let theme: TerminalColorTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Sample terminal output using theme colors
            HStack(spacing: 0) {
                coloredText("$ ", index: 2)    // green prompt
                coloredText("ls", index: nil)  // default fg
            }
            HStack(spacing: 0) {
                coloredText("src/", index: 4)       // blue (dir)
                coloredText("  ", index: nil)
                coloredText("README.md", index: nil) // default
                coloredText("  ", index: nil)
                coloredText("tests/", index: 4)      // blue (dir)
            }
            HStack(spacing: 0) {
                coloredText("error:", index: 1)       // red
                coloredText(" not found", index: nil)
            }
            HStack(spacing: 0) {
                coloredText("success:", index: 2)     // green
                coloredText(" build complete", index: nil)
            }
            HStack(spacing: 0) {
                coloredText("warning:", index: 3)     // yellow
                coloredText(" deprecated", index: nil)
            }

            // ANSI color swatch row
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { i in
                    swatch(index: i)
                }
                Spacer().frame(width: 4)
                ForEach(8..<16, id: \.self) { i in
                    swatch(index: i)
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(8)
        .background(Color(theme.backgroundColorValue))
        .cornerRadius(6)
    }

    private func coloredText(_ text: String, index: Int?) -> some View {
        let color: NSColor = if let index {
            TerminalColorTheme.nsColor(from: theme.ansiColors[index])
        } else {
            theme.foregroundColor
        }
        return Text(text).foregroundColor(Color(color))
    }

    private func swatch(index: Int) -> some View {
        let color = TerminalColorTheme.nsColor(from: theme.ansiColors[index])
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color(color))
            .frame(width: 14, height: 14)
    }
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
