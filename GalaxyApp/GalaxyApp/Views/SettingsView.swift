import SwiftUI
import UserNotifications
import Galactic

// MARK: - Settings Tab Definition

enum SettingsTab: String, CaseIterable {
    case general
    case sessions
    case terminal
    case files
    case statusline
    case notifications

    var title: String {
        switch self {
        case .general: return "General"
        case .sessions: return "Sessions"
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .statusline: return "Statusline"
        case .notifications: return "Notifications"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .sessions: return "text.bubble"
        case .terminal: return "apple.terminal"
        case .files: return "folder"
        case .statusline: return "dock.rectangle"
        case .notifications: return "bell"
        }
    }

    /// Width of the settings window's content for this tab. Most tabs
    /// use the standard narrow column; the statusline tab is dense
    /// enough to lay its sections out in two side-by-side columns, so
    /// it needs roughly double the width. The window follows this via
    /// the hosting controller's preferred content size — growing for
    /// statusline and shrinking back for the others.
    var contentWidth: CGFloat {
        switch self {
        case .statusline: return 900
        default: return 420
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsManager = SettingsManager.shared
    @State private var fontSizeText: String = ""
    @State private var scrollbackText: String = ""
    @State private var shellHeightPercentText: String = ""
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // Icon tab bar — capped to the standard column width and
            // centered, so the icons stay a clustered group rather
            // than spreading out when the window widens for the
            // statusline tab.
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
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)

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
                        scrollbackText: $scrollbackText,
                        shellHeightPercentText:
                            $shellHeightPercentText
                    )
                case .files:
                    FilesSettingsTab(settingsManager: settingsManager)
                case .notifications:
                    NotificationsSettingsTab(settingsManager: settingsManager)
                case .statusline:
                    StatuslineSettingsTab()
                }
            }
        }
        .frame(width: selectedTab.contentWidth)
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
                        .frame(width: 140, alignment: .trailing)
                    }

                    SettingsRow(label: "Theme") {
                        Picker("", selection: $settingsManager.settings.themePreference) {
                            ForEach(ThemePreference.allCases, id: \.self) { preference in
                                Label(preference.displayName, systemImage: preference.iconName)
                                    .tag(preference)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160, alignment: .trailing)
                    }
                }
            }

            // Not the Terminal tab: these keystrokes govern the WebView note
            // and annotation forms as well as the Claude session pane.
            SettingsCard(title: "Text entry") {
                VStack(alignment: .leading, spacing: 12) {
                    KeystrokeListEditor(
                        label: "Submit",
                        keystrokes: $settingsManager.settings.textEntry.submit,
                        siblingLabel: "Newline",
                        sibling: $settingsManager.settings.textEntry.newline
                    )
                    KeystrokeListEditor(
                        label: "Newline",
                        keystrokes: $settingsManager.settings.textEntry.newline,
                        siblingLabel: "Submit",
                        sibling: $settingsManager.settings.textEntry.submit
                    )
                    Text(
                        "Applies to note and annotation forms. A reader that is "
                            + "already open keeps its previous keystrokes until "
                            + "it is reopened."
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                    ClaudeKeybindingsSyncRow(
                        settingsManager: settingsManager)
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
                        .frame(width: 140, alignment: .trailing)
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
                                .frame(width: 100, alignment: .trailing)
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
    @Binding var shellHeightPercentText: String

    /// Drives the blur-normalize behavior for the shell
    /// height percent field. When focus leaves the field
    /// (or Return is pressed), we clamp out-of-range typed
    /// values and revert empty/invalid input to the
    /// current setting — so the visible text always
    /// honestly reflects what's in effect.
    @FocusState private var shellHeightFocused: Bool

    /// Called on blur / Return. Normalizes the shell
    /// height text field:
    /// - Valid integer in range → write to setting (idempotent)
    /// - Valid integer out of range → clamp, write, sync text
    /// - Empty / non-integer → revert text to current setting
    private func normalizeShellHeightText() {
        let range = AppSettings.shellDefaultHeightRatioRange
        let setting = settingsManager.settings
            .shellDefaultHeightRatio

        if let pct = Int(shellHeightPercentText) {
            let ratio = Double(pct) / 100.0
            let clamped = min(
                max(ratio, range.lowerBound),
                range.upperBound
            )
            if clamped != setting {
                settingsManager.settings
                    .shellDefaultHeightRatio = clamped
            }
            let clampedPct = Int((clamped * 100).rounded())
            let newText = "\(clampedPct)"
            if shellHeightPercentText != newText {
                shellHeightPercentText = newText
            }
        } else {
            // Empty or non-numeric → revert to setting
            let pct = Int((setting * 100).rounded())
            shellHeightPercentText = "\(pct)"
        }
    }

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
                        .frame(width: 160, alignment: .trailing)
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
                VStack(alignment: .leading, spacing: 6) {
                    SettingsRow(label: "Buffer size") {
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

                            Text("·")
                                .foregroundColor(.secondary)

                            Text(AppSettings.estimatedScrollbackMemory(
                                lines: settingsManager.settings.terminalScrollbackLines
                            ))
                            .foregroundColor(.secondary)

                            Text("\u{2020}")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("\u{2020} Based on 200-column terminal width")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.leading, 2)

                    Divider()

                    Toggle("Scroll up to enter scrollback view",
                           isOn: $settingsManager.settings.scrollToEnterScrollback)
                        .toggleStyle(.checkbox)
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
                        .frame(width: 180, alignment: .trailing)
                    }

                    ThemePreviewView(
                        theme: TerminalColorTheme.theme(
                            named: settingsManager.settings.terminalColorThemeName
                        )
                    )
                }
            }

            // Cursor — applies to both the session (Claude) and
            // shell terminal panes.
            SettingsCard(title: "Cursor") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Style") {
                        Picker(
                            "",
                            selection: $settingsManager.settings
                                .terminalCursorStyle
                        ) {
                            ForEach(
                                ShellCursorStyle.allCases,
                                id: \.self
                            ) { style in
                                Text(style.displayName)
                                    .tag(style)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140, alignment: .trailing)
                    }

                    HStack {
                        Toggle(
                            "Blink",
                            isOn: $settingsManager.settings
                                .terminalCursorBlink
                        )
                        .toggleStyle(.checkbox)
                        Spacer()
                    }
                }
            }

            // Shell pane settings
            SettingsCard(title: "Shell") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Default height") {
                        HStack(spacing: 4) {
                            TextField("", text: $shellHeightPercentText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .multilineTextAlignment(.trailing)
                                .focused($shellHeightFocused)
                                .onAppear {
                                    let pct = Int(
                                        (settingsManager.settings
                                            .shellDefaultHeightRatio
                                            * 100).rounded()
                                    )
                                    shellHeightPercentText = "\(pct)"
                                }
                                .onChange(of: shellHeightPercentText) { _, newValue in
                                    // As-you-type: only commit to the
                                    // setting when the typed value is a
                                    // valid integer inside the allowed
                                    // range. This preserves mid-typing
                                    // states like "3" on the way to "35"
                                    // without clobbering the setting —
                                    // the blur/submit handler normalizes
                                    // final state.
                                    guard let pct = Int(newValue)
                                    else { return }
                                    let ratio = Double(pct) / 100.0
                                    if AppSettings
                                        .shellDefaultHeightRatioRange
                                        .contains(ratio) {
                                        settingsManager.settings
                                            .shellDefaultHeightRatio = ratio
                                    }
                                }
                                .onChange(of: shellHeightFocused) { _, isFocused in
                                    if !isFocused {
                                        normalizeShellHeightText()
                                    }
                                }
                                .onSubmit {
                                    normalizeShellHeightText()
                                }
                                .onChange(of: settingsManager.settings
                                    .shellDefaultHeightRatio
                                ) { _, newValue in
                                    let pct = Int(
                                        (newValue * 100).rounded()
                                    )
                                    let newText = "\(pct)"
                                    if shellHeightPercentText != newText {
                                        shellHeightPercentText = newText
                                    }
                                }

                            Stepper(
                                "",
                                value: $settingsManager.settings
                                    .shellDefaultHeightRatio,
                                in: AppSettings
                                    .shellDefaultHeightRatioRange,
                                step: AppSettings
                                    .shellDefaultHeightRatioStep
                            )
                            .labelsHidden()

                            Text("%")
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    HStack {
                        Toggle(
                            "Audible bell",
                            isOn: $settingsManager.settings
                                .shellBellAudible
                        )
                        .toggleStyle(.checkbox)
                        Spacer()
                    }

                    if settingsManager.settings
                        .shellBellAudible {
                        SettingsRow(label: "Sound") {
                            HStack(spacing: 8) {
                                Picker(
                                    "",
                                    selection:
                                        $settingsManager.settings
                                        .shellBellSound
                                ) {
                                    Text(
                                        SoundPreference.none
                                            .displayName
                                    )
                                    .tag(SoundPreference.none)
                                    Text(
                                        SoundPreference.system
                                            .displayName
                                    )
                                    .tag(SoundPreference.system)

                                    Divider()

                                    ForEach(
                                        SoundPreference.allCases
                                            .filter { $0.isSound },
                                        id: \.self
                                    ) { pref in
                                        Text(pref.displayName)
                                            .tag(pref)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 130, alignment: .trailing)

                                Button(action: {
                                    settingsManager.playSound(
                                        settingsManager.settings
                                            .shellBellSound
                                    )
                                }) {
                                    Image(
                                        systemName: "play.fill"
                                    )
                                    .font(.system(size: 10))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Preview bell sound")
                            }
                        }
                    }

                    HStack {
                        Toggle(
                            "Visual bell",
                            isOn: $settingsManager.settings
                                .shellBellVisualFlash
                        )
                        .toggleStyle(.checkbox)
                        Spacer()
                    }
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

// MARK: - Notifications Tab

struct NotificationsSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var authStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(spacing: 16) {
            // Section 1: Terminal bell alerts
            SettingsCard(title: "Terminal bell") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Sound") {
                        HStack(spacing: 8) {
                            Picker(
                                "",
                                selection:
                                    $settingsManager.settings
                                    .bellSound
                            ) {
                                Text(
                                    SoundPreference.none
                                        .displayName
                                )
                                .tag(SoundPreference.none)
                                Text(
                                    SoundPreference.system
                                        .displayName
                                )
                                .tag(SoundPreference.system)

                                Divider()

                                ForEach(
                                    SoundPreference.allCases
                                        .filter { $0.isSound },
                                    id: \.self
                                ) { pref in
                                    Text(pref.displayName)
                                        .tag(pref)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130, alignment: .trailing)

                            Button(action: {
                                settingsManager.playSound(
                                    settingsManager.settings
                                        .bellSound
                                )
                            }) {
                                Image(
                                    systemName: "play.fill"
                                )
                                .font(.system(size: 10))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Preview bell sound")
                        }
                    }

                    HStack {
                        Toggle(
                            "Visual bell",
                            isOn: $settingsManager.settings
                                .bellVisualFlash
                        )
                        .toggleStyle(.checkbox)
                        Spacer()
                    }
                }
            }

            // Section 2: Permission request alerts
            SettingsCard(title: "Permission request") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(label: "Sound") {
                        HStack(spacing: 8) {
                            Picker(
                                "",
                                selection:
                                    $settingsManager.settings
                                    .permissionRequestSound
                            ) {
                                Text(
                                    SoundPreference.none
                                        .displayName
                                )
                                .tag(SoundPreference.none)
                                Text(
                                    SoundPreference.system
                                        .displayName
                                )
                                .tag(SoundPreference.system)

                                Divider()

                                ForEach(
                                    SoundPreference.allCases
                                        .filter { $0.isSound },
                                    id: \.self
                                ) { pref in
                                    Text(pref.displayName)
                                        .tag(pref)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130, alignment: .trailing)

                            Button(action: {
                                settingsManager.playSound(
                                    settingsManager.settings
                                        .permissionRequestSound
                                )
                            }) {
                                Image(
                                    systemName: "play.fill"
                                )
                                .font(.system(size: 10))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(
                                "Preview permission request"
                                + " sound"
                            )
                        }
                    }
                }
            }

            // Section 3: Indicators
            SettingsCard(title: "Indicators") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Toggle(
                            "Show unread indicator",
                            isOn: $settingsManager.settings
                                .showUnreadIndicator
                        )
                        .toggleStyle(.checkbox)
                        Spacer()
                    }

                    // Dock badge toggle with authorization
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle(
                                "Show dock badge",
                                isOn:
                                    $settingsManager.settings
                                    .showDockBadge
                            )
                            .toggleStyle(.checkbox)
                            .onChange(
                                of: settingsManager.settings
                                    .showDockBadge
                            ) { _, enabled in
                                if enabled {
                                    Task {
                                        let granted =
                                            await settingsManager
                                            .requestNotificationAuthorization()
                                        authStatus = granted
                                            ? .authorized
                                            : .denied
                                        SessionManager.shared
                                            .updateDockBadge()
                                    }
                                } else {
                                    NSApp.dockTile
                                        .badgeLabel = nil
                                }
                            }
                            Spacer()
                        }

                        if settingsManager.settings
                            .showDockBadge
                            && authStatus == .denied
                        {
                            HStack(spacing: 4) {
                                Text(
                                    "Badge disabled in"
                                    + " system settings."
                                )
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                Button(
                                    "Open Notification"
                                    + " Settings"
                                ) {
                                    settingsManager
                                        .openNotificationSettings()
                                }
                                .font(.system(size: 11))
                                .buttonStyle(.link)
                            }
                            .padding(.leading, 20)
                        }
                    }
                }
            }

            // Section 4: Session notifications
            SettingsCard(title: "Session") {
                VStack(alignment: .leading, spacing: 12) {
                    // Terminal Bell
                    HStack {
                        Toggle(
                            "Terminal bell",
                            isOn: $settingsManager.settings
                                .notifyTerminalBell
                        )
                        .toggleStyle(.checkbox)
                        .onChange(
                            of: settingsManager.settings
                                .notifyTerminalBell
                        ) { _, enabled in
                            if enabled { requestAuth() }
                        }
                        Spacer()
                    }

                    // Permission Request
                    HStack {
                        Toggle(
                            "Permission request",
                            isOn: $settingsManager.settings
                                .notifyPermissionRequest
                        )
                        .toggleStyle(.checkbox)
                        .onChange(
                            of: settingsManager.settings
                                .notifyPermissionRequest
                        ) { _, enabled in
                            if enabled { requestAuth() }
                        }
                        Spacer()
                    }

                    // Session Idle
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle(
                                "Session idle",
                                isOn: $settingsManager.settings
                                    .notifySessionIdle
                            )
                            .toggleStyle(.checkbox)
                            .onChange(
                                of: settingsManager.settings
                                    .notifySessionIdle
                            ) { _, enabled in
                                if enabled { requestAuth() }
                            }
                            Spacer()
                        }

                        if settingsManager.settings.notifySessionIdle {
                            SettingsRow(label: "Minimum busy time") {
                                HStack(spacing: 4) {
                                    Stepper(
                                        "\(settingsManager.settings.notifySessionIdleMinBusy)s",
                                        value: $settingsManager.settings
                                            .notifySessionIdleMinBusy,
                                        in: AppSettings
                                            .notifySessionIdleMinBusyRange
                                    )
                                    .frame(width: 100, alignment: .trailing)
                                }
                            }
                            .padding(.leading, 20)

                            SettingsRow(label: "Minimum idle time") {
                                HStack(spacing: 4) {
                                    Stepper(
                                        "\(settingsManager.settings.notifySessionIdleMinIdle)s",
                                        value: $settingsManager.settings
                                            .notifySessionIdleMinIdle,
                                        in: AppSettings
                                            .notifySessionIdleMinIdleRange
                                    )
                                    .frame(width: 100, alignment: .trailing)
                                }
                            }
                            .padding(.leading, 20)

                            SettingsRow(label: "Sound") {
                                HStack(spacing: 8) {
                                    Picker(
                                        "",
                                        selection:
                                            $settingsManager.settings
                                            .notifySessionIdleSound
                                    ) {
                                        Text(
                                            SoundPreference.none
                                                .displayName
                                        )
                                        .tag(SoundPreference.none)
                                        Text(
                                            SoundPreference.system
                                                .displayName
                                        )
                                        .tag(SoundPreference.system)

                                        Divider()

                                        ForEach(
                                            SoundPreference.allCases
                                                .filter { $0.isSound },
                                            id: \.self
                                        ) { pref in
                                            Text(pref.displayName)
                                                .tag(pref)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 130, alignment: .trailing)

                                    Button(action: {
                                        settingsManager.playSound(
                                            settingsManager.settings
                                                .notifySessionIdleSound
                                        )
                                    }) {
                                        Image(
                                            systemName: "play.fill"
                                        )
                                        .font(.system(size: 10))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help(
                                        "Preview session idle sound"
                                    )
                                }
                            }
                            .padding(.leading, 20)
                        }
                    }

                    // Session Exited Unexpectedly
                    HStack {
                        Toggle(
                            "Session exited unexpectedly",
                            isOn: $settingsManager.settings
                                .notifySessionExitedUnexpectedly
                        )
                        .toggleStyle(.checkbox)
                        .onChange(
                            of: settingsManager.settings
                                .notifySessionExitedUnexpectedly
                        ) { _, enabled in
                            if enabled { requestAuth() }
                        }
                        Spacer()
                    }

                    // High Context Warning
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle(
                                "High context warning",
                                isOn: $settingsManager.settings
                                    .notifyHighContext
                            )
                            .toggleStyle(.checkbox)
                            .onChange(
                                of: settingsManager.settings
                                    .notifyHighContext
                            ) { _, enabled in
                                if enabled { requestAuth() }
                            }
                            Spacer()
                        }

                        if settingsManager.settings.notifyHighContext {
                            SettingsRow(label: "Threshold") {
                                HStack(spacing: 4) {
                                    Stepper(
                                        "\(settingsManager.settings.notifyHighContextThreshold)%",
                                        value: $settingsManager.settings
                                            .notifyHighContextThreshold,
                                        in: AppSettings
                                            .notifyHighContextThresholdRange
                                    )
                                    .frame(width: 100, alignment: .trailing)
                                }
                            }
                            .padding(.leading, 20)
                        }
                    }

                    // Auto-Clear Occurred
                    HStack {
                        Toggle(
                            "Auto-clear occurred",
                            isOn: $settingsManager.settings
                                .notifyAutoClearOccurred
                        )
                        .toggleStyle(.checkbox)
                        .onChange(
                            of: settingsManager.settings
                                .notifyAutoClearOccurred
                        ) { _, enabled in
                            if enabled { requestAuth() }
                        }
                        Spacer()
                    }

                    // Authorization warning when any session
                    // notification is enabled but system permission
                    // is denied
                    if hasAnySessionNotificationEnabled
                        && authStatus == .denied
                    {
                        HStack(spacing: 4) {
                            Text(
                                "Notifications disabled in system"
                                + " settings."
                            )
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            Button("Open Notification Settings") {
                                settingsManager
                                    .openNotificationSettings()
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.link)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .task {
            await refreshAuthStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSWindow.didBecomeKeyNotification
            )
        ) { _ in
            Task { await refreshAuthStatus() }
        }
    }

    private var hasAnySessionNotificationEnabled: Bool {
        let s = settingsManager.settings
        return s.notifySessionIdle
            || s.notifySessionExitedUnexpectedly
            || s.notifyHighContext
            || s.notifyAutoClearOccurred
            || s.notifyTerminalBell
            || s.notifyPermissionRequest
    }

    private func requestAuth() {
        Task {
            let granted = await settingsManager
                .requestNotificationAuthorization()
            authStatus = granted ? .authorized : .denied
        }
    }

    private func refreshAuthStatus() async {
        let settings = await UNUserNotificationCenter.current()
            .notificationSettings()
        authStatus = settings.authorizationStatus
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
