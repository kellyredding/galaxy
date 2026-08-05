import Foundation

/// What was true about the app at the instant the cheat sheet opened.
///
/// Captured once rather than read live, and that is load-bearing. The
/// sheet's own search field takes first responder as it appears, so a
/// live reading of pane focus would be false the whole time the sheet is
/// up and every ⌘S, ⌃←, and interrupt row would dim — the exact inverse
/// of the truth. Worse for the readers: the escape monitors in
/// `ArtifactsView` and `SnapshotsView` are app-wide and gate on
/// `activeTab`, so live state cannot tell "the reader is behind the
/// sheet" from "the reader has focus". Snapshotting before the overlay
/// mounts keeps the rows describing the surface *behind* the sheet,
/// which is the surface the reader is asking about.
///
/// Two levels, because Galaxy's surface is two levels: which view is
/// showing, and — on the Ledger only — which sub-tab within it. Ten
/// distinct surfaces come out of that pair, and every one of them
/// answers ↩ differently.
///
/// Deliberately carries no "a text field has focus" flag. assist-ant
/// needs one because its view-switch keys stand aside for a focused
/// editor; none of Galaxy's do, so recording it here would add a field
/// no case may read and invite one to start.
struct KeystrokeContext: Equatable {

    // MARK: - Surface

    let tab: SessionTab
    /// Meaningful only when `tab == .ledger`, and read only there.
    let ledgerSubTab: LedgerSubTab

    // MARK: - Sessions

    /// Any session in the list, active or not. Distinct from the next
    /// field on purpose: sessions can exist with none active, which is
    /// the state the File menu keeps a dead ⌘W placeholder for.
    let hasSessions: Bool
    let hasActiveSession: Bool
    let activeSessionRunning: Bool
    let activeSessionExited: Bool
    /// Answered from `SidebarPreferences.shared.isVisible`, which is the
    /// same narrow publisher `validateMenuItem` gates Hide / Show on —
    /// not `AppSettings.isSidebarVisible`, which only seeds it at launch
    /// and is written back a runloop later.
    let sessionsPanelVisible: Bool

    // MARK: - Readers

    /// Two flags rather than one, because `SessionManager` publishes two
    /// and they move independently — an artifact reader left open on one
    /// tab says nothing about the snapshot reader on another.
    let artifactReaderOpen: Bool
    let snapshotReaderOpen: Bool

    // MARK: - Agents

    /// An agent run is selected, so the Agents tab has something open to
    /// dismiss.
    ///
    /// Not a reader — nothing is hosted, the detail simply replaces the
    /// list — but it gates a key the same way a reader does, which is why
    /// it sits beside them rather than under Surface. `AgentsView`
    /// installs its Escape monitor only while `selectedAgent != nil`, so
    /// without this the Escape row reads live on an Agents list with
    /// nothing selected and Escape does nothing at all.
    let agentRunOpen: Bool

    // MARK: - Terminal

    let sessionPaneFocused: Bool
    let shellPaneFocused: Bool
    /// A scrollback overlay is up on the pane the caret is in.
    ///
    /// Answered per pane, from `TerminalPaneCoordinator.scrollbackOpenKinds`.
    /// It began as a session-pane-only flag — which existed to tell a shell
    /// whether it could send to the agent, and was right for that — so these
    /// rows read dimmed for a shell scrollback, which is exactly the surface
    /// they describe. The pane's own answer is now recorded for every pane and
    /// this asks about the focused one.
    let scrollbackOpen: Bool

    let findBarOpen: Bool

    // MARK: - Derived

    /// The caret is in either terminal pane.
    var paneFocused: Bool { sessionPaneFocused || shellPaneFocused }

    /// Whether the thing `tab` opens over its list is open.
    ///
    /// "Reader" is the name because two of the three are literal reader
    /// web views. The Agents tab's detail is not hosted in one — it
    /// simply replaces the list — but it answers the same question a
    /// reader does, and every keystroke that consults this wants the
    /// question, not the mechanism. The remaining three views open
    /// nothing over their content, so they answer false rather than
    /// reaching for a flag that does not describe them.
    func readerOpen(on tab: SessionTab) -> Bool {
        switch tab {
        case .artifacts: return artifactReaderOpen
        case .snapshots: return snapshotReaderOpen
        case .agents: return agentRunOpen
        case .terminal, .timeline, .ledger: return false
        }
    }

    /// Whether a focusable list is on screen.
    ///
    /// A third statement of the switch that `buildViewMenu` holds as a
    /// local `let` and `openFocusedItemDescriptor` holds as a `switch`.
    /// Restating it is the cost of a hand-authored catalog and is taken
    /// knowingly: the gate is a local binding with no name to call.
    /// Folding all three onto `KeystrokeCatalog.ledgerListSubTabs` is
    /// the fix and is deliberately a later step.
    var hasListFocus: Bool {
        switch tab {
        case .snapshots, .artifacts, .agents:
            return true
        case .ledger:
            return KeystrokeCatalog.ledgerListSubTabs.contains(ledgerSubTab)
        case .terminal, .timeline:
            return false
        }
    }

    /// A resting main window: one Terminal tab, nothing focused, nothing
    /// open. Every value is the app's own launch default —
    /// `SessionManager` starts on `.terminal` and `.identifiers`, and
    /// `AppSettings` ships the panel visible — so this is a state Galaxy
    /// really passes through rather than a convenient zero.
    static let empty = KeystrokeContext(
        tab: .terminal,
        ledgerSubTab: .identifiers,
        hasSessions: false,
        hasActiveSession: false,
        activeSessionRunning: false,
        activeSessionExited: false,
        sessionsPanelVisible: true,
        artifactReaderOpen: false,
        snapshotReaderOpen: false,
        agentRunOpen: false,
        sessionPaneFocused: false,
        shellPaneFocused: false,
        scrollbackOpen: false,
        findBarOpen: false
    )
}
