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
        // Orange with abandoned, because both mean the agent
        // never finished. Not red: a cancellation is something
        // we asked for, and nothing went wrong.
        case "abandoned", "canceled": return .orange
        default: return .secondary
        }
    }

    var statusLabel: String {
        switch status {
        case "running": return "Running"
        case "stopped": return "Stopped"
        case "failed": return "Failed"
        case "abandoned": return "Abandoned"
        case "canceled": return "Canceled"
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
        ListTimestamp.format(startedAt)
    }
}
