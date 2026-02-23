import Foundation

/// Tabs available in the session views area.
/// Adding a new tab: add a case here, add the view branch in
/// ContentView's activeViewContent, and add a menu shortcut.
enum SessionTab: String, CaseIterable {
    case terminal
    case ledger

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .ledger: return "Ledger"
        }
    }

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .ledger: return "book.closed"
        }
    }
}
