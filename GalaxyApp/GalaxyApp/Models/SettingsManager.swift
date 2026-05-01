import Foundation
import SwiftUI
import Combine
import AVFoundation
import UserNotifications

/// Sidebar position preference
enum SidebarPosition: String, Codable, CaseIterable {
    case left = "left"
    case right = "right"

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// Theme preference options
enum ThemePreference: String, Codable, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var displayName: String {
        switch self {
        case .system: return "Match system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

/// Sound preference for terminal bell and permission request
enum SoundPreference: String, Codable, CaseIterable {
    case system = "system"
    case none = "none"
    // macOS system sounds
    case basso = "Basso"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case glass = "Glass"
    case hero = "Hero"
    case morse = "Morse"
    case ping = "Ping"
    case pop = "Pop"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case tink = "Tink"

    var displayName: String {
        switch self {
        case .system: return "System Beep"
        case .none: return "None"
        default: return rawValue
        }
    }

    var isSound: Bool {
        switch self {
        case .system, .none:
            return false
        default:
            return true
        }
    }
}

/// Legacy bell preference — kept only for migration from
/// older settings files that used the single-enum approach.
private enum LegacyBellPreference: String, Codable {
    case system = "system"
    case visualBell = "visualBell"
    case none = "none"
    case basso = "Basso"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case glass = "Glass"
    case hero = "Hero"
    case morse = "Morse"
    case ping = "Ping"
    case pop = "Pop"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case tink = "Tink"
}

/// Git status display style for sidebar session rows
enum GitStatusStyle: String, Codable, CaseIterable {
    case symbolic = "symbolic"
    case arrows = "arrows"
    case minimal = "minimal"

    var displayName: String {
        switch self {
        case .symbolic: return "Symbolic"
        case .arrows: return "Arrows"
        case .minimal: return "Minimal"
        }
    }
}

/// Shape of the cursor rendered in the Shell pane. Pairs
/// with `shellCursorBlink` to pick one of SwiftTerm's six
/// `CursorStyle` cases at apply time (see
/// `SwiftTermBackend.applyCursor`).
///
/// User-facing settings keep style + blink as two
/// orthogonal knobs because that's the clearer mental
/// model; the backend is where the two collapse into
/// SwiftTerm's native enum.
enum ShellCursorStyle: String, Codable, CaseIterable {
    case block = "block"
    case underline = "underline"
    case verticalBar = "verticalBar"

    var displayName: String {
        switch self {
        case .block: return "Block"
        case .underline: return "Underline"
        case .verticalBar: return "Vertical Bar"
        }
    }
}

/// Persistent settings for the Galaxy app
struct AppSettings: Codable, Equatable {
    var sidebarPosition: SidebarPosition = .left
    var sidebarWidth: CGFloat = 220.0  // Width of sessions panel
    var isSidebarVisible: Bool = true  // Sidebar expanded/collapsed state
    var themePreference: ThemePreference = .system
    var bellSound: SoundPreference = .system
    var bellVisualFlash: Bool = false
    var permissionRequestSound: SoundPreference = .none
    var showUnreadIndicator: Bool = true
    var showDockBadge: Bool = false

    // Font settings
    var terminalFontFamily: String = "SF Mono"  // Terminal font family (must be monospaced)
    var chromeFontSize: CGFloat = 13.0  // Base font size for app chrome (sidebar, labels, etc.)
    var defaultTerminalFontSize: CGFloat = 13.0  // Default font size for new terminal sessions

    // Terminal color settings
    var terminalColorThemeName: String = "terminal-classic"  // Active color theme

    // Terminal scrollback settings
    var terminalScrollbackLines: Int = 10_000  // Scrollback buffer size in lines

    /// Active terminal engine. Global default; each pane
    /// pins to whichever engine was active at its construction
    /// time (D-pane). Flipping this never affects already-
    /// running panes — see `TerminalBackendFactory`. No UI
    /// surface yet; the toggle ships when libghostty
    /// integration ships.
    var terminalEngine: TerminalEngine = .swiftTerm

    // Shell pane settings
    /// Default split ratio for a newly opened shell pane,
    /// expressed as the shell's fraction of total height
    /// (0.0–1.0). The top (session) pane gets `1 - ratio`.
    /// Clamped to `shellDefaultHeightRatioRange` on apply
    /// so the stored value can't drift outside the same
    /// window the drag indicator enforces. Applied at open
    /// time only — changing this while a shell is already
    /// open does NOT retroactively resize it (matches
    /// `defaultTerminalFontSize` semantics).
    var shellDefaultHeightRatio: Double = 0.5

    /// Cursor shape for the Shell pane. Default `.block`
    /// matches macOS Terminal.app's default. Shell-only —
    /// the Session pane's SwiftTerm caret is hidden by
    /// Claude Code's own cursor rendering.
    var shellCursorStyle: ShellCursorStyle = .block
    /// Whether the Shell pane cursor blinks. Default off
    /// because a steady cursor is less distracting in a
    /// secondary pane where the user's visual focus is
    /// usually the Claude session above.
    var shellCursorBlink: Bool = false

    /// Whether the Shell pane plays a sound on BEL.
    /// Default off — routine shell events (e.g.
    /// backspace at line start) should not nag the user
    /// by default.
    var shellBellAudible: Bool = false
    /// Sound played when `shellBellAudible` is on.
    /// Defaults to `.system` so users who flip the
    /// audible toggle on get something immediately
    /// audible without having to pick.
    var shellBellSound: SoundPreference = .system
    /// Whether the Shell pane briefly flashes an overlay
    /// on BEL. Default on — silent-but-noticeable feedback
    /// is the sweet spot for a secondary pane.
    var shellBellVisualFlash: Bool = true

    // Session sidebar settings
    var gitStatusStyle: GitStatusStyle = .symbolic  // Git status display style

    // Scrollback behavior settings
    var scrollToEnterScrollback: Bool = false  // Scroll-up enters scrollback view

    // Session behavior settings
    var autoClearEnabled: Bool = true  // Auto-clear when context exceeds threshold
    var autoClearThreshold: Int = 97   // Context percentage (0-100) that triggers auto-clear

    // Session notification settings
    var notifySessionIdle: Bool = false
    var notifySessionIdleMinBusy: Int = 1  // seconds
    var notifySessionIdleMinIdle: Int = 3  // seconds
    var notifySessionIdleSound: SoundPreference = .none
    var notifySessionExitedUnexpectedly: Bool = false
    var notifyHighContext: Bool = false
    var notifyHighContextThreshold: Int = 90
    var notifyAutoClearOccurred: Bool = false
    var notifyTerminalBell: Bool = false
    var notifyPermissionRequest: Bool = false

    // Sidebar width constraints
    static let sidebarWidthRange: ClosedRange<CGFloat> = 150...500

    // Font size constraints
    static let chromeFontSizeRange: ClosedRange<CGFloat> = 8...24
    static let chromeFontSizeStep: CGFloat = 2
    static let terminalFontSizeRange: ClosedRange<CGFloat> = 10...24
    static let terminalFontSizeStep: CGFloat = 1

    // Auto-clear threshold constraints
    static let autoClearThresholdRange: ClosedRange<Int> = 50...99

    // Notification constraints
    static let notifySessionIdleMinBusyRange: ClosedRange<Int> = 1...60
    static let notifySessionIdleMinIdleRange: ClosedRange<Int> = 1...60
    static let notifyHighContextThresholdRange: ClosedRange<Int> = 50...99

    // Scrollback constraints
    static let terminalScrollbackRange: ClosedRange<Int> = 500...100_000

    // Shell pane default height constraints. The same 30–70%
    // window the drag indicator enforces, so the setting can't
    // be configured outside the usable range.
    static let shellDefaultHeightRatioRange:
        ClosedRange<Double> = 0.30...0.70
    /// Stepper increment for the Settings UI. 1% nudges
    /// give fine-grained control; text field accepts any
    /// integer percent inside the range.
    static let shellDefaultHeightRatioStep: Double = 0.01

    /// Estimated memory usage for a given scrollback line count.
    /// Assumes 200-column terminal width at 16 bytes per cell (3,200 bytes/line).
    /// Always rounds up to the nearest whole MB.
    static func estimatedScrollbackMemory(lines: Int) -> String {
        let megabytes = ceil(Double(lines) * 3_200.0 / 1_000_000.0)
        return "~\(Int(megabytes)) MB"
    }

    // Restore session modal column widths
    var restoreColNameWidth: CGFloat = 250
    var restoreColPersonaWidth: CGFloat = 100
    var restoreColDirectoryWidth: CGFloat = 100
    var restoreColClosedWidth: CGFloat = 110

    // Restore session modal column width constraints (per-column minimums
    // sized to fit the header label at 11pt medium weight)
    static let restoreColNameMinWidth: CGFloat = 50
    static let restoreColPersonaMinWidth: CGFloat = 65
    static let restoreColDirectoryMinWidth: CGFloat = 75
    static let restoreColClosedMinWidth: CGFloat = 60
    static let restoreColMaxWidth: CGFloat = 500

    // New session defaults (scoped to in-app session creation)
    var newSessionDefaultDir: String = "~/"       // Default start directory for new sessions
    var newSessionLastPersona: String? = nil      // Last-used persona name

    static let `default` = AppSettings()

    // Custom decoder to handle missing keys gracefully when adding new settings
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sidebarPosition = try container.decodeIfPresent(SidebarPosition.self, forKey: .sidebarPosition) ?? .left
        sidebarWidth = try container.decodeIfPresent(CGFloat.self, forKey: .sidebarWidth) ?? 220.0
        isSidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .isSidebarVisible) ?? true
        themePreference = try container.decodeIfPresent(ThemePreference.self, forKey: .themePreference) ?? .system
        // Bell sound + visual flash: try new keys first, migrate
        // from legacy bellPreference if present.
        if let sound = try container.decodeIfPresent(
            SoundPreference.self, forKey: .bellSound
        ) {
            bellSound = sound
        } else {
            // Migrate from old single-enum bellPreference
            let oldKey = CodingKeys(stringValue: "bellPreference")!
            if let old = try container.decodeIfPresent(
                LegacyBellPreference.self, forKey: oldKey
            ) {
                switch old {
                case .visualBell:
                    bellSound = .none
                    bellVisualFlash = true
                case .none:
                    bellSound = .none
                default:
                    bellSound = SoundPreference(
                        rawValue: old.rawValue
                    ) ?? .system
                }
                NSLog(
                    "SettingsManager: Migrated legacy"
                    + " bellPreference '%@'",
                    old.rawValue
                )
            }
        }
        bellVisualFlash = try container.decodeIfPresent(
            Bool.self, forKey: .bellVisualFlash
        ) ?? bellVisualFlash
        permissionRequestSound = try container.decodeIfPresent(
            SoundPreference.self,
            forKey: .permissionRequestSound
        ) ?? .none
        showUnreadIndicator = try container.decodeIfPresent(Bool.self, forKey: .showUnreadIndicator) ?? true
        showDockBadge = try container.decodeIfPresent(Bool.self, forKey: .showDockBadge) ?? false
        terminalFontFamily = try container.decodeIfPresent(String.self, forKey: .terminalFontFamily) ?? "SF Mono"
        chromeFontSize = try container.decodeIfPresent(CGFloat.self, forKey: .chromeFontSize) ?? 13.0
        defaultTerminalFontSize = try container.decodeIfPresent(CGFloat.self, forKey: .defaultTerminalFontSize) ?? 13.0
        terminalColorThemeName = try container.decodeIfPresent(String.self, forKey: .terminalColorThemeName) ?? "terminal-classic"
        terminalScrollbackLines = try container.decodeIfPresent(Int.self, forKey: .terminalScrollbackLines) ?? 10_000
        terminalEngine = try container.decodeIfPresent(
            TerminalEngine.self, forKey: .terminalEngine
        ) ?? .swiftTerm
        gitStatusStyle = try container.decodeIfPresent(GitStatusStyle.self, forKey: .gitStatusStyle) ?? .symbolic
        autoClearEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoClearEnabled) ?? true
        autoClearThreshold = try container.decodeIfPresent(Int.self, forKey: .autoClearThreshold) ?? 97
        scrollToEnterScrollback = try container.decodeIfPresent(
            Bool.self, forKey: .scrollToEnterScrollback) ?? false
        notifySessionIdle = try container.decodeIfPresent(
            Bool.self, forKey: .notifySessionIdle) ?? false
        notifySessionIdleMinBusy = try container.decodeIfPresent(
            Int.self, forKey: .notifySessionIdleMinBusy) ?? 1
        notifySessionIdleMinIdle = try container.decodeIfPresent(
            Int.self, forKey: .notifySessionIdleMinIdle) ?? 3
        notifySessionIdleSound = try container.decodeIfPresent(
            SoundPreference.self,
            forKey: .notifySessionIdleSound
        ) ?? .none
        notifySessionExitedUnexpectedly = try container.decodeIfPresent(
            Bool.self, forKey: .notifySessionExitedUnexpectedly) ?? false
        notifyHighContext = try container.decodeIfPresent(
            Bool.self, forKey: .notifyHighContext) ?? false
        notifyHighContextThreshold = try container.decodeIfPresent(
            Int.self, forKey: .notifyHighContextThreshold) ?? 90
        notifyAutoClearOccurred = try container.decodeIfPresent(
            Bool.self, forKey: .notifyAutoClearOccurred) ?? false
        notifyTerminalBell = try container.decodeIfPresent(
            Bool.self, forKey: .notifyTerminalBell) ?? false
        notifyPermissionRequest = try container.decodeIfPresent(
            Bool.self, forKey: .notifyPermissionRequest
        ) ?? false
        restoreColNameWidth = try container.decodeIfPresent(
            CGFloat.self, forKey: .restoreColNameWidth) ?? 250
        restoreColPersonaWidth = try container.decodeIfPresent(
            CGFloat.self, forKey: .restoreColPersonaWidth) ?? 100
        restoreColDirectoryWidth = try container.decodeIfPresent(
            CGFloat.self, forKey: .restoreColDirectoryWidth) ?? 100
        restoreColClosedWidth = try container.decodeIfPresent(
            CGFloat.self, forKey: .restoreColClosedWidth) ?? 110
        newSessionDefaultDir = try container.decodeIfPresent(String.self, forKey: .newSessionDefaultDir) ?? "~/"
        newSessionLastPersona = try container.decodeIfPresent(String.self, forKey: .newSessionLastPersona)
        shellDefaultHeightRatio = try container.decodeIfPresent(
            Double.self, forKey: .shellDefaultHeightRatio
        ) ?? 0.5
        shellCursorStyle = try container.decodeIfPresent(
            ShellCursorStyle.self, forKey: .shellCursorStyle
        ) ?? .block
        shellCursorBlink = try container.decodeIfPresent(
            Bool.self, forKey: .shellCursorBlink
        ) ?? false
        shellBellAudible = try container.decodeIfPresent(
            Bool.self, forKey: .shellBellAudible
        ) ?? false
        shellBellSound = try container.decodeIfPresent(
            SoundPreference.self, forKey: .shellBellSound
        ) ?? .system
        shellBellVisualFlash = try container.decodeIfPresent(
            Bool.self, forKey: .shellBellVisualFlash
        ) ?? true
    }

    init() {
        // Use defaults
    }
}

/// Manages app settings with persistence to disk
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings {
        didSet {
            save()
        }
    }

    private let settingsURL: URL
    private var audioPlayer: AVAudioPlayer?

    private init() {
        // Set up settings directory and file path
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let galaxyDir = appSupport.appendingPathComponent("Galaxy", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: galaxyDir, withIntermediateDirectories: true)

        self.settingsURL = galaxyDir.appendingPathComponent("settings.json")

        // Load existing settings or use defaults
        self.settings = SettingsManager.load(from: settingsURL) ?? AppSettings.default

        NSLog("SettingsManager: Settings loaded from %@", settingsURL.path)
    }

    private static func load(from url: URL) -> AppSettings? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)

            // Merge approach: read existing as dictionary, merge with defaults, then decode
            // This ensures existing settings are never lost when adding new fields
            guard var existingDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("SettingsManager: Settings file is not a valid JSON object")
                return nil
            }

            // Get defaults as dictionary
            let defaultSettings = AppSettings.default
            let defaultData = try JSONEncoder().encode(defaultSettings)
            guard let defaultDict = try JSONSerialization.jsonObject(with: defaultData) as? [String: Any] else {
                return nil
            }

            // Merge: only add keys from defaults that don't exist in saved settings
            for (key, value) in defaultDict {
                if existingDict[key] == nil {
                    existingDict[key] = value
                    NSLog("SettingsManager: Added missing setting '%@' with default value", key)
                }
            }

            // Convert merged dictionary back to data and decode
            let mergedData = try JSONSerialization.data(withJSONObject: existingDict)
            let settings = try JSONDecoder().decode(AppSettings.self, from: mergedData)
            return settings
        } catch {
            NSLog("SettingsManager: Failed to load settings: %@", error.localizedDescription)
            return nil
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
            NSLog("SettingsManager: Settings saved")
        } catch {
            NSLog("SettingsManager: Failed to save settings: %@", error.localizedDescription)
        }
    }

    // MARK: - Notification Authorization

    /// Check current notification authorization status without prompting.
    func checkNotificationAuthorization() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current()
            .notificationSettings()
        return settings.authorizationStatus
    }

    /// Request notification authorization from the system. Shows the
    /// permission dialog only if status is .notDetermined (first time).
    /// Requests alert, sound, and badge — a single grant covers all
    /// notification features (dock badge, session notifications, etc.).
    func requestNotificationAuthorization() async -> Bool {
        let status = await checkNotificationAuthorization()

        switch status {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(
                        options: [.alert, .sound, .badge]
                    )
                return granted
            } catch {
                NSLog(
                    "SettingsManager: Authorization request failed: %@",
                    error.localizedDescription
                )
                return false
            }
        default:
            return false
        }
    }

    /// Open System Settings to Galaxy's notification preferences.
    func openNotificationSettings() {
        let base = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "\(base)?id=\(bundleId)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Play a sound based on the given preference.
    /// Reusable for terminal bell, permission request, etc.
    func playSound(_ preference: SoundPreference) {
        switch preference {
        case .system:
            NSSound.beep()
        case .none:
            break
        default:
            // Play named macOS system sound
            let soundPath = "/System/Library/Sounds/"
                + "\(preference.rawValue).aiff"
            let url = URL(fileURLWithPath: soundPath)
            do {
                audioPlayer = try AVAudioPlayer(
                    contentsOf: url
                )
                audioPlayer?.play()
            } catch {
                NSLog(
                    "SettingsManager: Failed to play"
                    + " sound: %@",
                    error.localizedDescription
                )
                NSSound.beep()  // Fallback
            }
        }
    }
}
