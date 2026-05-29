import SwiftUI

// MARK: - Top-level tab

/// Settings tab for the galaxy-statusline CLI. Driven entirely by
/// shelling out to the CLI via StatuslineConfigService. The
/// installation section is always visible; the rest of the form
/// only appears when the hook is installed and points at the
/// galaxy-managed binary.
struct StatuslineSettingsTab: View {
    @StateObject private var service = StatuslineConfigService()

    /// Width of a single settings card / column. Wider than the other
    /// tabs' standard column so each color row can fit its label, color
    /// picker, and inline Bold checkbox on one line.
    private static let columnWidth: CGFloat = 420

    /// Cap the scrollable region to the visible screen height (less an
    /// allowance for the title bar, tab bar, and margins). Below the
    /// cap the window sizes to content; beyond it the content scrolls
    /// rather than running off the bottom of the display.
    private var maxContentHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 160
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hook + Preview stay full-card width, stacked and
                // centered above the two columns.
                StatuslineInstallationSection(service: service)
                    .frame(width: Self.columnWidth)

                if let status = service.hookStatus,
                   status.installed,
                   status.matchesExpectedCommand,
                   let config = service.config {
                    StatuslinePreviewSection(
                        service: service,
                        config: config
                    )
                    .frame(width: Self.columnWidth)

                    HStack(alignment: .top, spacing: 20) {
                        // Left column: Display, Layout, thresholds.
                        VStack(spacing: 16) {
                            StatuslineDisplaySection(
                                service: service,
                                config: config
                            )
                            StatuslineLayoutSection(
                                service: service,
                                config: config
                            )
                            StatuslineThresholdsSection(
                                service: service,
                                config: config
                            )
                        }
                        .frame(width: Self.columnWidth)

                        // Right column: Colors.
                        VStack(spacing: 16) {
                            StatuslineColorsSection(
                                service: service,
                                config: config
                            )
                        }
                        .frame(width: Self.columnWidth)
                    }

                    StatuslineFooterSection(service: service)
                        .frame(width: Self.columnWidth)
                }

                if let err = service.lastError {
                    Text(err.localizedDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .frame(
                            width: Self.columnWidth, alignment: .leading
                        )
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: maxContentHeight)
        .task {
            await service.refresh()
        }
    }
}

// MARK: - Installation section

struct StatuslineInstallationSection: View {
    @ObservedObject var service: StatuslineConfigService

    var body: some View {
        SettingsCard(title: "Hook") {
            Group {
                if service.hookStatus == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundColor(.secondary)
                    }
                } else if let status = service.hookStatus {
                    if status.installed && status.matchesExpectedCommand {
                        installedView
                    } else if status.installed {
                        conflictView(status: status)
                    } else {
                        notInstalledView
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(service.inFlight > 0)
    }

    private var installedView: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            Text("Installed").bold()
            Spacer()
            Button("Uninstall") {
                Task { await service.uninstallHook() }
            }
        }
    }

    private func conflictView(status: StatuslineHookStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text("Third-party hook installed").bold()
                Spacer()
            }
            Text(status.command ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            Text(
                "Galaxy will not modify a hook it didn't install. "
                + "Remove this hook manually from "
                + status.settingsPath
                + " if you want to use the Galaxy statusline."
            )
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notInstalledView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.gray).frame(width: 8, height: 8)
                Text("Not installed").bold()
                Spacer()
            }
            Text(
                "The Claude Code statusline hook isn't registered. "
                + "Install to enable the Galaxy statusline. "
                + "Uninstalling later preserves your configuration."
            )
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Install") {
                    Task { await service.installHook() }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
    }
}

// MARK: - Display section

private let statuslineLabelWidth: CGFloat = 150

/// A label + trailing-aligned control row for the statusline tab's
/// left column. The fixed-width label keeps every label flush at the
/// same left edge, and the control hugs the trailing edge — so the
/// time-format field, the style pickers, and the width steppers all
/// share one right edge regardless of their individual widths.
private struct StatuslineFormRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: statuslineLabelWidth, alignment: .leading)
            control
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct StatuslineDisplaySection: View {
    @ObservedObject var service: StatuslineConfigService
    let config: StatuslineConfig

    var body: some View {
        SettingsCard(title: "Display") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Show cost",
                    isOn: bindBool(
                        \.layout.showCost,
                        key: "layout.show_cost"
                    )
                )
                .toggleStyle(.checkbox)

                Toggle(
                    "Show model",
                    isOn: bindBool(
                        \.layout.showModel,
                        key: "layout.show_model"
                    )
                )
                .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Show time",
                        isOn: bindBool(
                            \.layout.showTime,
                            key: "layout.show_time"
                        )
                    )
                    .toggleStyle(.checkbox)

                    if config.layout.showTime {
                        StatuslineFormRow(label: "Format") {
                            StatuslineTimeFormatField(
                                value: config.layout.timeFormat,
                                onCommit: { newValue in
                                    Task {
                                        await service.setConfigKey(
                                            "layout.time_format",
                                            value: newValue
                                        )
                                    }
                                }
                            )
                        }
                    }
                }

                StatuslineFormRow(label: "Directory style") {
                    enumPicker(
                        \.layout.directoryStyle,
                        key: "layout.directory_style",
                        options: [
                            "full", "smart", "basename", "short",
                        ]
                    )
                }

                StatuslineFormRow(label: "Branch style") {
                    enumPicker(
                        \.branchStyle,
                        key: "branch_style",
                        options: [
                            "symbolic", "arrows", "minimal",
                        ]
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(service.inFlight > 0)
    }

    private func bindBool(
        _ keyPath: KeyPath<StatuslineConfig, Bool>,
        key: String
    ) -> Binding<Bool> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { newValue in
                Task {
                    await service.setConfigKey(
                        key, value: newValue ? "true" : "false"
                    )
                }
            }
        )
    }

    private func enumPicker(
        _ keyPath: KeyPath<StatuslineConfig, String>,
        key: String,
        options: [String]
    ) -> some View {
        Picker(
            "",
            selection: Binding(
                get: { config[keyPath: keyPath] },
                set: { newValue in
                    Task {
                        await service.setConfigKey(
                            key, value: newValue
                        )
                    }
                }
            )
        ) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
    }
}

/// Time format field: free-text TextField (commits on submit/blur)
/// + a menu of strftime presets that overwrite the field value.
struct StatuslineTimeFormatField: View {
    let value: String
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    private static let presets: [(label: String, format: String)] = [
        ("12-hour",              "%-I:%M %^p"),
        ("12-hour with seconds", "%-I:%M:%S %^p"),
        ("24-hour",              "%H:%M"),
        ("24-hour with seconds", "%H:%M:%S"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .font(.system(size: 11, design: .monospaced))
                .focused($focused)
                .onAppear { text = value }
                .onChange(of: value) { _, new in text = new }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused && text != value { onCommit(text) }
                }
                .onSubmit { onCommit(text) }

            Menu("Presets") {
                ForEach(Self.presets, id: \.format) { preset in
                    Button(preset.label) {
                        text = preset.format
                        onCommit(preset.format)
                    }
                }
            }
            .frame(width: 90)
        }
    }
}

// MARK: - Layout section

struct StatuslineLayoutSection: View {
    @ObservedObject var service: StatuslineConfigService
    let config: StatuslineConfig

    var body: some View {
        SettingsCard(title: "Layout") {
            VStack(alignment: .leading, spacing: 12) {
                StatuslineFormRow(label: "Context bar min width") {
                    Stepper(
                        "\(config.layout.contextBarMinWidth)%",
                        value: bindInt(
                            \.layout.contextBarMinWidth,
                            key: "layout.context_bar_min_width"
                        ),
                        in: 1...200
                    )
                }

                StatuslineFormRow(label: "Context bar max width") {
                    Stepper(
                        "\(config.layout.contextBarMaxWidth)%",
                        value: bindInt(
                            \.layout.contextBarMaxWidth,
                            key: "layout.context_bar_max_width"
                        ),
                        in: 1...200
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(service.inFlight > 0)
    }

    private func bindInt(
        _ keyPath: KeyPath<StatuslineConfig, Int>,
        key: String
    ) -> Binding<Int> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { newValue in
                Task {
                    await service.setConfigKey(
                        key, value: String(newValue)
                    )
                }
            }
        )
    }
}

// MARK: - Thresholds section

struct StatuslineThresholdsSection: View {
    @ObservedObject var service: StatuslineConfigService
    let config: StatuslineConfig

    var body: some View {
        SettingsCard(title: "Context thresholds") {
            VStack(alignment: .leading, spacing: 12) {
                thresholdRow(
                    label: "Warning",
                    value: config.contextThresholds.warning,
                    key: "context_thresholds.warning"
                )
                thresholdRow(
                    label: "Critical",
                    value: config.contextThresholds.critical,
                    key: "context_thresholds.critical"
                )
            }
        }
        .disabled(service.inFlight > 0)
    }

    private func thresholdRow(
        label: String, value: Int, key: String
    ) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { newValue in
                        Task {
                            await service.setConfigKey(
                                key, value: String(Int(newValue))
                            )
                        }
                    }
                ),
                in: 0...100,
                step: 1
            )
            Text("\(value)%")
                .frame(width: 40, alignment: .trailing)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Colors section

struct StatuslineColorsSection: View {
    @ObservedObject var service: StatuslineConfigService
    let config: StatuslineConfig

    private struct ColorField {
        let label: String
        let key: String
        let keyPath: KeyPath<StatuslineConfig.Colors, String>
    }

    private struct ColorGroup {
        let title: String
        let fields: [ColorField]
    }

    private static let groups: [ColorGroup] = [
        ColorGroup(title: "Directory & Branch", fields: [
            ColorField(
                label: "Directory",
                key: "colors.directory",
                keyPath: \.directory
            ),
            ColorField(
                label: "Branch",
                key: "colors.branch",
                keyPath: \.branch
            ),
        ]),
        ColorGroup(title: "Git status", fields: [
            ColorField(
                label: "Behind upstream",
                key: "colors.upstream_behind",
                keyPath: \.upstreamBehind
            ),
            ColorField(
                label: "Ahead upstream",
                key: "colors.upstream_ahead",
                keyPath: \.upstreamAhead
            ),
            ColorField(
                label: "Synced",
                key: "colors.upstream_synced",
                keyPath: \.upstreamSynced
            ),
            ColorField(
                label: "Dirty",
                key: "colors.dirty",
                keyPath: \.dirty
            ),
            ColorField(
                label: "Staged",
                key: "colors.staged",
                keyPath: \.staged
            ),
            ColorField(
                label: "Stashed",
                key: "colors.stashed",
                keyPath: \.stashed
            ),
        ]),
        ColorGroup(title: "Context", fields: [
            ColorField(
                label: "Normal",
                key: "colors.context_normal",
                keyPath: \.contextNormal
            ),
            ColorField(
                label: "Warning",
                key: "colors.context_warning",
                keyPath: \.contextWarning
            ),
            ColorField(
                label: "Critical",
                key: "colors.context_critical",
                keyPath: \.contextCritical
            ),
        ]),
        ColorGroup(title: "Stats", fields: [
            ColorField(
                label: "Model",
                key: "colors.model",
                keyPath: \.model
            ),
            ColorField(
                label: "Cost",
                key: "colors.cost",
                keyPath: \.cost
            ),
            ColorField(
                label: "Time",
                key: "colors.time",
                keyPath: \.time
            ),
        ]),
    ]

    var body: some View {
        SettingsCard(title: "Colors") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(
                                .system(
                                    size: 11,
                                    weight: .medium
                                )
                            )
                            .foregroundColor(.secondary)
                        ForEach(
                            group.fields, id: \.key
                        ) { field in
                            StatuslineColorRow(
                                label: field.label,
                                rawValue:
                                    config.colors[
                                        keyPath: field.keyPath
                                    ],
                                onCommit: { newValue in
                                    Task {
                                        await service
                                            .setConfigKey(
                                                field.key,
                                                value: newValue
                                            )
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
        .disabled(service.inFlight > 0)
    }
}

struct StatuslineColorRow: View {
    let label: String
    let rawValue: String
    let onCommit: (String) -> Void

    private var parsed: StatuslineColorValue {
        StatuslineColorValue.parse(rawValue)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 130, alignment: .leading)

            Picker(
                "",
                selection: Binding(
                    get: { parsed.color },
                    set: { newColor in
                        let next = StatuslineColorValue(
                            color: newColor, bold: parsed.bold
                        )
                        onCommit(next.wireValue)
                    }
                )
            ) {
                ForEach(StatuslineColorName.allCases) { name in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(name.swatch)
                            .frame(width: 10, height: 10)
                        Text(name.displayName)
                    }
                    .tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 170)

            // Bold sits inline to the right of the color picker so each
            // color setting is a single row — halving the Colors
            // column height versus stacking Bold beneath the picker.
            Toggle(
                "Bold",
                isOn: Binding(
                    get: { parsed.bold },
                    set: { newBold in
                        let next = StatuslineColorValue(
                            color: parsed.color, bold: newBold
                        )
                        onCommit(next.wireValue)
                    }
                )
            )
            .toggleStyle(.checkbox)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Preview section

/// Live preview of the status line using the CLI's `preview`
/// subcommand. Re-renders whenever the config changes, parses
/// the ANSI-encoded output, and composes colored Text rows.
///
/// Visual layout mirrors ThemePreviewView: monospace, padded,
/// rounded background that hints at a terminal pane.
struct StatuslinePreviewSection: View {
    @ObservedObject var service: StatuslineConfigService
    let config: StatuslineConfig

    @State private var lines: [[StatuslineANSIChunk]] = []

    var body: some View {
        SettingsCard(title: "Preview") {
            VStack(alignment: .leading, spacing: 2) {
                if lines.isEmpty {
                    Text(" ")  // reserve a row of vertical space
                } else {
                    ForEach(lines.indices, id: \.self) { i in
                        renderedLine(for: lines[i])
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(NSColor.textBackgroundColor).opacity(0.5)
            )
            .cornerRadius(6)
        }
        .task(id: config) {
            await refresh()
        }
    }

    /// Build a single Text from the chunks of one line by
    /// folding `+` over each chunk's styled fragment. SwiftUI's
    /// `Text.+` preserves attributes, so colors and bold survive
    /// the concatenation into one rendered run.
    private func renderedLine(
        for chunks: [StatuslineANSIChunk]
    ) -> some View {
        let combined = chunks.reduce(Text("")) { acc, chunk in
            acc + chunk.styledText()
        }
        return combined
    }

    private func refresh() async {
        do {
            let raw = try await service.renderSample()
            lines = StatuslineANSIParser.parse(raw)
        } catch {
            // Swallow preview errors — surfacing them in the
            // dedicated error band below the form is enough.
            // Empty `lines` falls back to the placeholder row.
            lines = []
        }
    }
}

// MARK: - Footer section

struct StatuslineFooterSection: View {
    @ObservedObject var service: StatuslineConfigService

    var body: some View {
        HStack {
            Button("Reset to defaults") {
                Task { await service.resetConfig() }
            }
            Spacer()
            Button("Reveal config in Finder") {
                let path = "\(NSHomeDirectory())"
                    + "/.claude/galaxy/statusline/config.json"
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: path)]
                )
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 12)
        .disabled(service.inFlight > 0)
    }
}
