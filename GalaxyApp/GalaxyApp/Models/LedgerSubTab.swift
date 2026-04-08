import Foundation

/// Subtabs within the Ledger view for drilling into session data.
/// State is global on SessionManager (not per-session), not persisted.
enum LedgerSubTab: String, CaseIterable {
    case identifiers = "Identifiers"
    case files = "Files"
    case entries = "Entries"
    case lastActivity = "Last activity"
    case suggestedName = "Suggested name"

    var icon: String {
        switch self {
        case .identifiers: return "number"
        case .files: return "doc.text"
        case .entries: return "list.bullet"
        case .lastActivity: return "clock"
        case .suggestedName: return "sparkles"
        }
    }
}
