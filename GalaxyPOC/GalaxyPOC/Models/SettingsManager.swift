import Foundation
import SwiftUI
import Combine

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

/// Persistent settings for the Galaxy app
struct AppSettings: Codable {
    var themePreference: ThemePreference = .system

    static let `default` = AppSettings()
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
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
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

    /// Returns the effective color scheme based on settings and system preference
    func effectiveColorScheme(systemScheme: ColorScheme) -> ColorScheme {
        switch settings.themePreference {
        case .system:
            return systemScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
