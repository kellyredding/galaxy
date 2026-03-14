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

/// Bell notification preference
enum BellPreference: String, Codable, CaseIterable {
    case system = "system"
    case visualBell = "visualBell"
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
        case .visualBell: return "Visual Bell"
        case .none: return "None"
        default: return rawValue
        }
    }

    var isSound: Bool {
        switch self {
        case .system, .visualBell, .none:
            return false
        default:
            return true
        }
    }
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

/// Persistent settings for the Galaxy app
struct AppSettings: Codable {
    var sidebarPosition: SidebarPosition = .left
    var sidebarWidth: CGFloat = 220.0  // Width of sessions panel
    var isSidebarVisible: Bool = true  // Sidebar expanded/collapsed state
    var themePreference: ThemePreference = .system
    var bellPreference: BellPreference = .system
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

    // Session sidebar settings
    var gitStatusStyle: GitStatusStyle = .symbolic  // Git status display style

    // Session behavior settings
    var autoClearEnabled: Bool = true  // Auto-clear when context exceeds threshold
    var autoClearThreshold: Int = 97   // Context percentage (0-100) that triggers auto-clear

    // Session notification settings
    var notifySessionIdle: Bool = false
    var notifySessionIdleMinBusy: Int = 3  // seconds
    var notifySessionIdleMinIdle: Int = 3  // seconds
    var notifySessionExitedUnexpectedly: Bool = false
    var notifyHighContext: Bool = false
    var notifyHighContextThreshold: Int = 90
    var notifyAutoClearOccurred: Bool = false
    var notifySnapshotCreated: Bool = false

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

    /// Estimated memory usage for a given scrollback line count.
    /// Assumes 200-column terminal width at 16 bytes per cell (3,200 bytes/line).
    /// Always rounds up to the nearest whole MB.
    static func estimatedScrollbackMemory(lines: Int) -> String {
        let megabytes = ceil(Double(lines) * 3_200.0 / 1_000_000.0)
        return "~\(Int(megabytes)) MB"
    }

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
        bellPreference = try container.decodeIfPresent(BellPreference.self, forKey: .bellPreference) ?? .system
        showUnreadIndicator = try container.decodeIfPresent(Bool.self, forKey: .showUnreadIndicator) ?? true
        showDockBadge = try container.decodeIfPresent(Bool.self, forKey: .showDockBadge) ?? false
        terminalFontFamily = try container.decodeIfPresent(String.self, forKey: .terminalFontFamily) ?? "SF Mono"
        chromeFontSize = try container.decodeIfPresent(CGFloat.self, forKey: .chromeFontSize) ?? 13.0
        defaultTerminalFontSize = try container.decodeIfPresent(CGFloat.self, forKey: .defaultTerminalFontSize) ?? 13.0
        terminalColorThemeName = try container.decodeIfPresent(String.self, forKey: .terminalColorThemeName) ?? "terminal-classic"
        terminalScrollbackLines = try container.decodeIfPresent(Int.self, forKey: .terminalScrollbackLines) ?? 10_000
        gitStatusStyle = try container.decodeIfPresent(GitStatusStyle.self, forKey: .gitStatusStyle) ?? .symbolic
        autoClearEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoClearEnabled) ?? true
        autoClearThreshold = try container.decodeIfPresent(Int.self, forKey: .autoClearThreshold) ?? 97
        notifySessionIdle = try container.decodeIfPresent(
            Bool.self, forKey: .notifySessionIdle) ?? false
        notifySessionIdleMinBusy = try container.decodeIfPresent(
            Int.self, forKey: .notifySessionIdleMinBusy) ?? 3
        notifySessionIdleMinIdle = try container.decodeIfPresent(
            Int.self, forKey: .notifySessionIdleMinIdle) ?? 3
        notifySessionExitedUnexpectedly = try container.decodeIfPresent(
            Bool.self, forKey: .notifySessionExitedUnexpectedly) ?? false
        notifyHighContext = try container.decodeIfPresent(
            Bool.self, forKey: .notifyHighContext) ?? false
        notifyHighContextThreshold = try container.decodeIfPresent(
            Int.self, forKey: .notifyHighContextThreshold) ?? 90
        notifyAutoClearOccurred = try container.decodeIfPresent(
            Bool.self, forKey: .notifyAutoClearOccurred) ?? false
        notifySnapshotCreated = try container.decodeIfPresent(
            Bool.self, forKey: .notifySnapshotCreated) ?? false
        newSessionDefaultDir = try container.decodeIfPresent(String.self, forKey: .newSessionDefaultDir) ?? "~/"
        newSessionLastPersona = try container.decodeIfPresent(String.self, forKey: .newSessionLastPersona)
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

    /// Handle terminal bell based on user preference
    func handleBell() {
        let preference = settings.bellPreference

        switch preference {
        case .system:
            NSSound.beep()
        case .visualBell, .none:
            // Handled elsewhere or disabled
            break
        default:
            // Play custom sound
            let soundPath = "/System/Library/Sounds/\(preference.rawValue).aiff"
            let url = URL(fileURLWithPath: soundPath)
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.play()
            } catch {
                NSLog("SettingsManager: Failed to play sound: %@", error.localizedDescription)
                NSSound.beep()  // Fallback
            }
        }
    }
}
