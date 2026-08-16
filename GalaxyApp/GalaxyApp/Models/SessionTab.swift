import Foundation

/// Tabs available in the session views area.
/// Adding a new tab: add a case here, add the view branch in
/// ContentView's activeViewContent, and add a menu shortcut.
enum SessionTab: String, CaseIterable {
    case terminal
    case timeline
    case agents
    case artifacts
    case snapshots
    case ledger

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .ledger: return "Ledger"
        case .agents: return "Agents"
        case .artifacts: return "Artifacts"
        case .snapshots: return "Snapshots"
        case .timeline: return "Timeline"
        }
    }

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .ledger: return "book.closed"
        case .agents: return "person.3"
        case .artifacts: return "doc.text"
        case .snapshots: return "camera.viewfinder"
        case .timeline: return "clock.arrow.circlepath"
        }
    }

    /// Whether this view has inner tabs, cycled with **⌘H/L** — the unshifted
    /// pair acts on the innermost thing you are in. ⇧⌘H/L is one level out and
    /// switches the view itself, whatever this answers.
    ///
    /// Claiming this is not enough on its own. It enables the menu item and
    /// lights up the cheat-sheet row, but the cycling itself is a switch in
    /// `SessionManager` that has to name the view too.
    var hasInnerTabs: Bool {
        switch self {
        case .terminal: return false
        case .ledger: return true
        case .agents: return false
        case .artifacts: return false
        case .snapshots: return false
        case .timeline: return false
        }
    }
}
