import Foundation
import SwiftUI
import Combine
import AVFoundation

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
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
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

/// Persistent settings for the Galaxy app
struct AppSettings: Codable {
    var sidebarPosition: SidebarPosition = .left
    var sidebarWidth: CGFloat = 220.0  // Width of sessions panel
    var themePreference: ThemePreference = .system
    var bellPreference: BellPreference = .system
    var showBellBadge: Bool = true

    // Font size settings
    var chromeFontSize: CGFloat = 13.0  // Base font size for app chrome (sidebar, labels, etc.)
    var defaultTerminalFontSize: CGFloat = 13.0  // Default font size for new terminal sessions

    // Sidebar width constraints
    static let sidebarWidthRange: ClosedRange<CGFloat> = 150...500

    // Font size constraints
    static let chromeFontSizeRange: ClosedRange<CGFloat> = 8...24
    static let chromeFontSizeStep: CGFloat = 2
    static let terminalFontSizeRange: ClosedRange<CGFloat> = 10...24
    static let terminalFontSizeStep: CGFloat = 1

    static let `default` = AppSettings()

    // Custom decoder to handle missing keys gracefully when adding new settings
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sidebarPosition = try container.decodeIfPresent(SidebarPosition.self, forKey: .sidebarPosition) ?? .left
        sidebarWidth = try container.decodeIfPresent(CGFloat.self, forKey: .sidebarWidth) ?? 220.0
        themePreference = try container.decodeIfPresent(ThemePreference.self, forKey: .themePreference) ?? .system
        bellPreference = try container.decodeIfPresent(BellPreference.self, forKey: .bellPreference) ?? .system
        showBellBadge = try container.decodeIfPresent(Bool.self, forKey: .showBellBadge) ?? true
        chromeFontSize = try container.decodeIfPresent(CGFloat.self, forKey: .chromeFontSize) ?? 13.0
        defaultTerminalFontSize = try container.decodeIfPresent(CGFloat.self, forKey: .defaultTerminalFontSize) ?? 13.0
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
        let galaxyDir = appSupport.appendingPathComponent("GalaxyPOC", isDirectory: true)

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
            try data.write(to: settingsURL)
            NSLog("SettingsManager: Settings saved")
        } catch {
            NSLog("SettingsManager: Failed to save settings: %@", error.localizedDescription)
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
