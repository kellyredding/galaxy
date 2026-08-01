import Foundation
import SwiftUI
import Combine
import AVFoundation
import UserNotifications
import Galactic

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
    var terminalColorThemeName: String = "galaxy-default"  // Active color theme

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

    /// Cursor shape for the terminal panes — applies to both the
    /// session (Claude) pane and the shell pane. Default `.block`
    /// matches macOS Terminal.app's default. The session pane shows
    /// the engine's native caret as Claude's prompt cursor, so this
    /// governs it too.
    var terminalCursorStyle: ShellCursorStyle = .block
    /// Whether the terminal cursor blinks. Default off for a steady,
    /// less-distracting cursor — matches Terminal/Ghostty's typical
    /// defaults and avoids the engine's blinking-block default.
    var terminalCursorBlink: Bool = false

    /// Which keystrokes commit text and which insert a newline. Governs the
    /// note and annotation forms directly, and reaches the Claude session pane
    /// by being written into Claude Code's own keybindings file. The default
    /// reproduces today's behaviour, so this is inert until someone changes it.
    var textEntry: TextEntryBindings = .default

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
    // The zoom window every terminal surface shares, derived from it rather
    // than restated so a pane and the settings that bound it cannot disagree.
    static let terminalFontSizeRange: ClosedRange<CGFloat> =
        TerminalFontSizeBounds.standard.range
    static let terminalFontSizeStep: CGFloat =
        TerminalFontSizeBounds.standard.step

    // Auto-clear threshold constraints
    static let autoClearThresholdRange: ClosedRange<Int> = 50...99

    // Notification constraints
    static let notifySessionIdleMinBusyRange: ClosedRange<Int> = 1...60
    static let notifySessionIdleMinIdleRange: ClosedRange<Int> = 1...60
    static let notifyHighContextThresholdRange: ClosedRange<Int> = 50...99

    // Scrollback constraints
    static let terminalScrollbackRange: ClosedRange<Int> = 500...100_000

    // Shell pane default height constraints — the same window the drag
    // enforces, derived from it rather than restated, so the setting cannot be
    // configured outside what a drag allows.
    //
    // Derived and not copied because the two are only the same numbers while
    // the window is symmetric: this one bounds the *shell* pane's share, the
    // drag bounds the pane above it.
    static let shellDefaultHeightRatioRange: ClosedRange<Double> =
        PaneSplitBounds.standard.bottomRange
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
        terminalColorThemeName = try container.decodeIfPresent(String.self, forKey: .terminalColorThemeName) ?? "galaxy-default"
        // Migration: rename the old "terminal-classic" id to
        // "galaxy-default". Existing settings would still resolve
        // correctly via the theme(named:) fallback, but normalizing
        // here means the next save persists the new id.
        if terminalColorThemeName == "terminal-classic" {
            terminalColorThemeName = "galaxy-default"
        }
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
        terminalCursorStyle = try container.decodeIfPresent(
            ShellCursorStyle.self, forKey: .terminalCursorStyle
        ) ?? .block
        terminalCursorBlink = try container.decodeIfPresent(
            Bool.self, forKey: .terminalCursorBlink
        ) ?? false
        textEntry = (try container.decodeIfPresent(
            TextEntryBindings.self, forKey: .textEntry
        ) ?? .default).coercingEmptyLists()
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

/// Conformance to the engine bridge's configuration seam. The
/// `GalacticConfiguration` protocol's member set is a strict
/// subset of `AppSettings` with identical names and types, so
/// the conformance is empty. See `GalacticConfiguration.swift`
/// for the protocol surface and the reasoning behind matching
/// `AppSettings`'s naming verbatim.
extension AppSettings: GalacticConfiguration { }

/// Manages app settings with persistence to disk
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings {
        didSet {
            save()
            // Only on an actual change: the file is global and shared with
            // assist-ant, so rewriting it because someone picked a theme would
            // stomp that app's bindings for no reason.
            if oldValue.textEntry != settings.textEntry {
                syncClaudeKeybindings()
            }
        }
    }

    /// Push the text-entry keystrokes into Claude Code's keybindings file.
    ///
    /// Failure is logged and swallowed. The file lives outside Galaxy, may be
    /// read-only or owned by something else, and a settings change that a user
    /// can see succeed in the card must not fail because a file elsewhere could
    /// not be written. The Settings pane reports sync state separately.
    func syncClaudeKeybindings() {
        do {
            let result = try ClaudeKeybindingsWriter.sync(settings.textEntry)
            if result.alreadyInSync {
                GalaxyLog.dbg("keybindings", "already in sync")
            } else {
                GalaxyLog.dbg(
                    "keybindings",
                    "wrote \(result.written.count) binding(s) to "
                        + ClaudeKeybindingsWriter.fileURL.path
                )
            }
            for keystroke in result.unsupported {
                GalaxyLog.dbg(
                    "keybindings",
                    "\(keystroke.displayLabel) has no Claude Code spelling — "
                        + "it works in the composers but not the session pane"
                )
            }
        } catch {
            GalaxyLog.dbg("keybindings", "sync failed — \(error)")
        }
    }

    /// Replace the text-entry keystrokes with the ones the keybindings file
    /// carries. The file wins, wholesale.
    ///
    /// Adopting deliberately writes the file back, by way of the settings
    /// `didSet` — which reads oddly until you look at what the alternative
    /// leaves behind. The adopted keystrokes come from the file, so the two
    /// already agree on those; what the file may still be missing is an
    /// explicit unbind on a key Claude Code binds by default. Without the
    /// write-back the card would report a difference the instant after
    /// adopting, over a key the user never touched. Writing converges both
    /// sides instead of leaving that dangling.
    ///
    /// Refuses when the file holds a binding the settings model cannot
    /// represent, rather than adopting the rest and dropping it silently.
    @discardableResult
    func adoptClaudeKeybindings() -> Bool {
        let state = ClaudeKeybindingsWriter.fileState(for: settings.textEntry)
        guard state.adoptable, let adopted = state.adopted else {
            GalaxyLog.dbg(
                "keybindings",
                "adopt refused — \(state.adoptRefusal ?? "nothing to adopt")"
            )
            return false
        }
        settings.textEntry = TextEntryBindings(
            submit: Self.merging(
                into: settings.textEntry.submit, adopted.submit),
            newline: Self.merging(
                into: settings.textEntry.newline, adopted.newline)
        ).coercingEmptyLists()

        // Written explicitly rather than left to the settings `didSet`, which
        // only fires when the lists actually change. Adopting can legitimately
        // leave them identical — a default already listed above, but not yet
        // spelled out in the file — and in that case the file still needs the
        // binding written or the card would go on reporting a difference that
        // pressing the button appeared to ignore.
        syncClaudeKeybindings()
        GalaxyLog.dbg("keybindings", "adopted the session pane's keystrokes")
        return true
    }

    /// Fold adopted keystrokes into an existing list, keeping the order that is
    /// already there and appending only what is new.
    ///
    /// Rebuilding the list outright would reorder keystrokes that did not
    /// change, because the adopted set arrives in the file's alphabetical order
    /// rather than the user's. Cosmetic on its own — order within a list does
    /// not affect matching — but these lists compare element-wise, so a
    /// reshuffle reads as a real edit, and adopting a file that already agreed
    /// would stop being the no-op it ought to be.
    private static func merging(
        into current: [Keystroke], _ adopted: [Keystroke]
    ) -> [Keystroke] {
        let incoming = Set(adopted)
        return current.filter(incoming.contains)
            + adopted.filter { !current.contains($0) }
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

        // Guarantee the reserved machine-submit chord before anything can send
        // a prompt. Only that one binding — never the user's keystrokes — so a
        // launch cannot stomp what assist-ant last wrote to this shared file.
        do {
            if try ClaudeKeybindingsWriter.ensureReservedBinding() {
                GalaxyLog.dbg(
                    "keybindings", "added the reserved machine-submit binding")
            }
        } catch {
            GalaxyLog.dbg(
                "keybindings",
                "could not ensure the reserved binding — \(error)"
            )
        }
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

    /// Background-queue serializer for narrow disk-only
    /// writes that bypass the fat `@Published var settings`
    /// publisher. Keeps the in-memory model untouched while
    /// still patching the on-disk JSON.
    private static let narrowPersistQueue = DispatchQueue(
        label: "com.galaxy.SettingsManager.narrowPersist"
    )

    /// Patch one field of the on-disk settings.json
    /// without mutating `settings` in memory. Used by
    /// `SidebarPreferences` so a sidebar toggle never
    /// fires the fat `objectWillChange` cascade. Read-
    /// modify-write on a serial background queue so
    /// concurrent narrow writes are ordered and never
    /// race the main-thread `save()` path.
    func persistSidebarVisibility(_ value: Bool) {
        let url = settingsURL
        Self.narrowPersistQueue.async {
            // Read current JSON dict, patch the one
            // field, encode back. Skips the @Published
            // wrapper entirely — the fat publisher does
            // NOT fire, no observer of SettingsManager
            // re-evaluates.
            guard
                let data = try? Data(contentsOf: url),
                var dict = try? JSONSerialization
                    .jsonObject(with: data)
                    as? [String: Any]
            else { return }
            dict["isSidebarVisible"] = value
            guard
                let merged = try? JSONSerialization
                    .data(withJSONObject: dict)
            else { return }
            do {
                try merged.write(
                    to: url, options: .atomic
                )
            } catch {
                NSLog(
                    "SettingsManager: narrow persist "
                    + "failed: %@",
                    error.localizedDescription
                )
            }
        }
    }

    private func save() {
        // Mirror narrow publishers' values into the
        // serialized struct so a save triggered by an
        // unrelated field change (e.g., font size step)
        // doesn't clobber the freshly-patched on-disk
        // sidebar value. The in-memory `settings.isSidebarVisible`
        // is intentionally not kept in sync with
        // `SidebarPreferences` to keep toggles off the fat
        // publisher; this snapshot is the rendezvous point.
        var settingsToSave = settings
        settingsToSave.isSidebarVisible =
            SidebarPreferences.shared.isVisible
        do {
            let data = try JSONEncoder().encode(settingsToSave)
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

/// Where shared terminal code reads configuration and hears about changes.
///
/// The deduplication happens here rather than in the engine because it needs the
/// concrete `AppSettings`, which is `Equatable`; the protocol the engine sees
/// cannot be. `dropFirst` because a published property replays its current value
/// to each new subscriber, and this contract promises changes only — the current
/// value is available synchronously and does not need announcing.
extension SettingsManager: GalacticConfigurationSource {
    var configuration: GalacticConfiguration { settings }

    var configurationChanges: AnyPublisher<GalacticConfiguration, Never> {
        $settings
            .removeDuplicates()
            .dropFirst()
            .map { $0 as GalacticConfiguration }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
