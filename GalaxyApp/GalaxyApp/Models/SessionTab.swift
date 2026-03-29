import Foundation

/// Tabs available in the session views area.
/// Adding a new tab: add a case here, add the view branch in
/// ContentView's activeViewContent, and add a menu shortcut.
enum SessionTab: String, CaseIterable {
    case terminal
    case ledger
    case snapshots
    case timeline

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .ledger: return "Ledger"
        case .snapshots: return "Snapshots"
        case .timeline: return "Timeline"
        }
    }

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .ledger: return "book.closed"
        case .snapshots: return "camera.viewfinder"
        case .timeline: return "chart.bar.xaxis"
        }
    }

    /// Whether this view has inner tabs that can be cycled with ⌘⇧H/L.
    var hasInnerTabs: Bool {
        switch self {
        case .terminal: return false
        case .ledger: return true
        case .snapshots: return false
        case .timeline: return false
        }
    }
}
