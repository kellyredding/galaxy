import Foundation

/// Tabs available in the session views area.
///
/// ### Adding a tab
///
/// There is no per-tab menu shortcut to add — the View menu only cycles, and
/// ⌘1-9 belong to sessions. What there is:
///
/// **The compiler will stop you**: `title`, `icon` and `hasInnerTabs` here;
/// `canActivateFind`, `hasListFocus` and `openFocusedItemDescriptor` in
/// `MainMenu`; `readerOpen(on:)` and `hasListFocus` in `KeystrokeContext`;
/// `KeystrokeSection.opening(for:)`; `deriveCurrentRoute`, `titleFor` and
/// `apply` in `NavigationCoordinator`; the two inner-tab cyclers and
/// `activateFind` in `SessionManager`; and check 13 in `KeystrokeSmoke`.
///
/// **Nothing will stop you**:
/// - `ContentView.activeViewContent` — the tab picker builds its button from
///   `allCases`, so the button appears and selects a blank pane. A debug build
///   now says so at first launch (see `TabPaneRegistry`), which is the closest
///   thing to enforcement available: `make check` builds and runs three
///   standalone tools and never launches the app.
/// - `KeystrokeCatalog.readerViews`, if the tab hosts a reader — eight rows
///   read it, and a tab absent from it silently has no reader keystrokes.
/// - `KeystrokeAvailability.item(_:)`, whose fallback prints "an artifact or
///   snapshot" for any tab it does not name.
/// - `NotificationService`'s decode of the `tab` string in `userInfo`, which
///   falls back to Terminal for a value it does not recognise.
/// - `isVisibleSurface`, spelled out by hand in three containers and threaded
///   through twenty-odd initialisers. A tab hosting a reader or a web view
///   needs its own, or it answers ⌘=/⌘-/⌘0 while hidden.
/// - `KeystrokeSmoke`'s surface cross-product and the "ten surfaces" arithmetic
///   in its comments, which a seventh tab makes twelve.
///
/// **Where the case sits in the enum** is the ⇧⌘H/L cycling order and the tab
/// strip's left-to-right order. Unlike Assist Ant there is no first-case
/// default: `activeTab` and `Session.lastActiveTab` both name Terminal
/// explicitly.
enum SessionTab: String, CaseIterable {
    case terminal
    case timeline
    case agents
    case artifacts
    case snapshots
    case ledger
    case files

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .ledger: return "Ledger"
        case .agents: return "Agents"
        case .artifacts: return "Artifacts"
        case .snapshots: return "Snapshots"
        case .timeline: return "Timeline"
        case .files: return "Files"
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
        case .files: return "folder"
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
        // The file strip, which is a second inner-tab axis and the only dynamic
        // one: Ledger's sub-tabs are a fixed enum, these are whatever is open.
        case .files: return true
        }
    }
}
