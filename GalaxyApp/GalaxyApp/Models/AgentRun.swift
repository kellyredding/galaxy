import SwiftUI

/// A single agent run decoded from galaxy-agents CLI JSON.
struct AgentRun: Codable, Identifiable {
    let agentId: String
    let agentType: String
    let description: String?
    let status: String
    let startedAt: String
    let completedAt: String?
    let durationMs: Int?
    let prompt: String?
    let lastMessage: String?
    let transcriptPath: String?

    var id: String { agentId }

    var isRunning: Bool { status == "running" }

    var statusColor: Color {
        switch status {
        case "running": return .green
        case "stopped": return .secondary
        case "failed": return .red
        case "abandoned": return .orange
        default: return .secondary
        }
    }

    var statusLabel: String {
        switch status {
        case "running": return "Running"
        case "stopped": return "Stopped"
        case "failed": return "Failed"
        case "abandoned": return "Abandoned"
        default: return status
        }
    }

    var displayDuration: String {
        guard let ms = durationMs else {
            return isRunning ? "…" : "—"
        }
        let seconds = Double(ms) / 1000.0
        if seconds >= 60 {
            return String(
                format: "%.1fm", seconds / 60.0
            )
        }
        return String(
            format: "%.1fs", seconds
        )
    }

    var displayStartedAt: String {
        Self.formatTimestamp(startedAt)
    }

    /// Parse "YYYY-MM-DD HH:MM:SS" (UTC) and format
    /// with tiered conciseness:
    ///   Today:      "4:03 PM"
    ///   This week:  "Mon 4:03 PM"
    ///   This year:  "Mar 30, 4:03 PM"
    ///   Older:      "Mar 30, 2025, 4:03 PM"
    private static let utcParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func formatTimestamp(
        _ ts: String
    ) -> String {
        guard let date = utcParser.date(from: ts)
        else { return ts }

        let cal = Calendar.current
        let now = Date()

        let fmt = DateFormatter()
        fmt.timeZone = .current

        if cal.isDateInToday(date) {
            // "4:03 PM"
            fmt.dateFormat = "h:mm a"
        } else if let weekAgo = cal.date(
            byAdding: .day, value: -6, to: now
        ), date >= weekAgo {
            // "Mon 4:03 PM"
            fmt.dateFormat = "EEE h:mm a"
        } else if cal.component(.year, from: date)
            == cal.component(.year, from: now)
        {
            // "Mar 30, 4:03 PM"
            fmt.dateFormat = "MMM d, h:mm a"
        } else {
            // "Mar 30, 2025, 4:03 PM"
            fmt.dateFormat = "MMM d, yyyy, h:mm a"
        }

        return fmt.string(from: date)
    }
}
