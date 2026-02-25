import Foundation

/// Subtabs within the Ledger view for drilling into session data.
/// State is global on SessionManager (not per-session), not persisted.
enum LedgerSubTab: String, CaseIterable {
    case lastActivity = "Last activity"
    case files = "Files"
    case entries = "Entries"
    case identifiers = "Identifiers"
    case suggestedName = "Suggested name"

    var icon: String {
        switch self {
        case .lastActivity: return "clock"
        case .files: return "doc.text"
        case .entries: return "list.bullet"
        case .identifiers: return "number"
        case .suggestedName: return "sparkles"
        }
    }
}
