import Foundation

/// Subtabs within the Ledger view for drilling into session data.
/// State is global on SessionManager (not per-session), not persisted.
enum LedgerSubTab: String, CaseIterable {
    case identifiers = "Identifiers"
    case fileAccess = "File access"
    case entries = "Entries"
    case lastActivity = "Last activity"
    case suggestedName = "Suggested name"

    var icon: String {
        switch self {
        case .identifiers: return "number"
        case .fileAccess: return "doc.badge.clock"
        case .entries: return "list.bullet"
        case .lastActivity: return "clock"
        case .suggestedName: return "sparkles"
        }
    }
}
