import Foundation
import SwiftUI

/// The full configuration emitted by `galaxy-statusline config`
/// as pretty-printed JSON. Decoded on every read; never persisted
/// app-side (the CLI owns the file at
/// ~/.claude/galaxy/statusline/config.json).
struct StatuslineConfig: Codable, Equatable {
    var version: String
    var colors: Colors
    var branchStyle: String
    var contextThresholds: ContextThresholds
    var layout: Layout

    struct Colors: Codable, Equatable {
        var directory: String
        var branch: String
        var upstreamBehind: String
        var upstreamAhead: String
        var upstreamSynced: String
        var dirty: String
        var staged: String
        var stashed: String
        var contextNormal: String
        var contextWarning: String
        var contextCritical: String
        var model: String
        var cost: String
        var time: String
    }

    struct ContextThresholds: Codable, Equatable {
        var warning: Int
        var critical: Int
    }

    struct Layout: Codable, Equatable {
        var contextBarMinWidth: Int
        var contextBarMaxWidth: Int
        var showCost: Bool
        var showModel: Bool
        var showTime: Bool
        var timeFormat: String
        var directoryStyle: String
    }
}

/// Valid color names accepted by `config set colors.X`. Mirrors
/// VALID_COLORS in tools/statusline/src/galaxy_statusline/config.cr.
enum StatuslineColorName: String, CaseIterable, Identifiable {
    case red, green, yellow, blue, magenta, cyan, white
    case brightRed = "bright_red"
    case brightGreen = "bright_green"
    case brightYellow = "bright_yellow"
    case brightBlue = "bright_blue"
    case brightMagenta = "bright_magenta"
    case brightCyan = "bright_cyan"
    case brightWhite = "bright_white"
    case `default`

    var id: String { rawValue }

    /// Approximate SwiftUI color for the picker swatch. Terminal
    /// rendering depends on the user's terminal theme — these are
    /// best-effort hints, not faithful reproductions.
    var swatch: Color {
        switch self {
        case .red, .brightRed:         return .red
        case .green, .brightGreen:     return .green
        case .yellow, .brightYellow:   return .yellow
        case .blue, .brightBlue:       return .blue
        case .magenta, .brightMagenta: return .pink
        case .cyan, .brightCyan:       return .cyan
        case .white, .brightWhite:     return .white
        case .default:                 return .secondary
        }
    }

    /// Human-readable label for picker rows.
    var displayName: String {
        switch self {
        case .red:           return "Red"
        case .green:         return "Green"
        case .yellow:        return "Yellow"
        case .blue:          return "Blue"
        case .magenta:       return "Magenta"
        case .cyan:          return "Cyan"
        case .white:         return "White"
        case .brightRed:     return "Bright red"
        case .brightGreen:   return "Bright green"
        case .brightYellow:  return "Bright yellow"
        case .brightBlue:    return "Bright blue"
        case .brightMagenta: return "Bright magenta"
        case .brightCyan:    return "Bright cyan"
        case .brightWhite:   return "Bright white"
        case .default:       return "Default"
        }
    }
}

/// Decompose the wire format ("bold:cyan", "yellow", etc.) into
/// (color, isBold) so the UI can drive two independent controls
/// per color setting.
struct StatuslineColorValue: Equatable {
    var color: StatuslineColorName
    var bold: Bool

    static func parse(_ raw: String) -> StatuslineColorValue {
        if raw.hasPrefix("bold:") {
            let suffix = String(raw.dropFirst("bold:".count))
            return StatuslineColorValue(
                color: StatuslineColorName(rawValue: suffix) ?? .default,
                bold: true
            )
        }
        return StatuslineColorValue(
            color: StatuslineColorName(rawValue: raw) ?? .default,
            bold: false
        )
    }

    var wireValue: String {
        bold ? "bold:\(color.rawValue)" : color.rawValue
    }
}
