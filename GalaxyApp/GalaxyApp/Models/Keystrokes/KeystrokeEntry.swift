import Foundation

/// Where a binding is usable.
///
/// One value drives both the dim state and the condition label, so a row
/// cannot look available while its text says otherwise. Foundation-only,
/// and evaluated against a snapshot rather than live app state — see
/// `KeystrokeContext` for why that distinction matters.
///
/// The cases are Galaxy's real gates, one apiece, rather than a general
/// scheme: a case that no row uses is a claim nobody checked, and a gate
/// with no case is a row that dims wrongly.
enum KeystrokeAvailability: Equatable {

    /// A menu command with no gate: live whenever Galaxy is frontmost.
    ///
    /// Also the home for the commands gated on a *value* rather than a
    /// surface — the chrome font size stops at its bounds — because
    /// dimming those would tell the reader the key does not exist here
    /// when the truth is that there is nothing left for it to do. The
    /// same principle is applied one level in by the rows that carry a
    /// surface gate *and* a bounds gate: Back and Forward name the
    /// session their history belongs to and say nothing about how deep
    /// it is.
    case app

    /// On one of these views, whatever is open over it.
    case views(Set<SessionTab>)

    /// On one of these views, with its reader open.
    ///
    /// Galaxy's two readers are the reason this is not `.views`: while a
    /// reader web view is in the window it consumes ⌘=/⌘-/⌘0 itself
    /// (`ReaderWebView.performKeyEquivalent`), so those keys mean one
    /// thing here and another on the Terminal tab. Reader-open is also
    /// what arms ⌘R Refresh and the annotation form's keys.
    case viewsWithReader(Set<SessionTab>)

    /// On one of these views, with nothing open over it.
    ///
    /// The other half of the pair, and the honest gate for ↩ — the
    /// descriptor disables Open on exactly the surfaces whose reader is
    /// already up, because the thing it would open is on screen.
    case viewsWithoutReader(Set<SessionTab>)

    /// On the Ledger, on one of these sub-tabs.
    ///
    /// Galaxy's inner level. Two of the five sub-tabs host a focusable
    /// list and three do not, and no set of outer tabs can say that.
    case ledgerSubTabs(Set<LedgerSubTab>)

    /// On a view that has inner tabs at all.
    ///
    /// Asked of `SessionTab.hasInnerTabs` rather than written as
    /// `[.ledger]`, so a second view growing inner tabs does not leave
    /// this row lying about it.
    case innerTabs

    // MARK: - Where a key re-scopes on the Files tab
    //
    // ⌘W and ⇧⌘T each mean one thing there and another everywhere else, and
    // the File menu builds one item or the other rather than both — two items
    // sharing a key equivalent leave one silently unbound. These four cases
    // are what keeps the sheet saying the same thing the menu does: without
    // them both meanings of a key read as live at once, on a key that can only
    // ever do one of them.

    /// Live anywhere the Files tab is not showing.
    case appOffFiles
    /// A session requirement that also stands down on the Files tab.
    case sessionOffFiles(SessionRequirement)
    /// On the Files tab, with a closed file to bring back.
    case filesWithClosed
    /// On the Files tab, with more than one row to step between. One row is
    /// not a thing to move between, and the menu item dims there.
    case filesWithRows

    /// Where a list has focus, in the sense `buildViewMenu` means it.
    ///
    /// Restates a gate that is a local `let` inside that method rather
    /// than a property, so there is nothing to call. Deliberately *not*
    /// folded together with `.viewsWithoutReader`: the two disagree on
    /// purpose — an open artifact reader still answers ⇧⌘J, and no
    /// longer answers ↩ — and a single case would have to pick one of
    /// those truths and print it over the other.
    case listFocus

    /// Something about the session list or the active session's state.
    case session(SessionRequirement)

    /// Something about which terminal pane the caret is in.
    case pane(PaneRequirement)

    /// With a scrollback overlay open.
    case scrollback

    /// With the find bar up.
    case findBar

    /// With the sessions panel in this state — exactly one of the pair
    /// is live at any moment, which is worth showing rather than
    /// flattening.
    case sessionsPanel(visible: Bool)

    /// Inside a separate window with its own key handling, named for the
    /// row's condition text.
    case dialog(String)

    // MARK: - Requirements

    /// How much of a session a row needs.
    ///
    /// Six states rather than a boolean because the File menu branches
    /// five ways on ⌘W and ⌘R alone, and a row that claimed "with a
    /// session" for all of them would show four live ⌘W rows at once.
    enum SessionRequirement: Equatable {
        /// No sessions at all — the state in which ⌘W closes the window.
        case absent
        /// At least one session exists, active or not. Reachable with
        /// none active, which is exactly why the File menu keeps a dead
        /// ⌘W placeholder for that case.
        case present
        /// A session is the active one.
        case active
        /// Active and not exited. What ⌘W Stop is offered on — briefly
        /// wider than `.running`, in the window after a session is
        /// created and before its backend comes up.
        case live
        /// Active, started, and not exited. What Clear and Compact need.
        case running
        /// Active and exited.
        case stopped
        /// Exited, *and* no artifact reader claiming ⌘R for Refresh.
        /// The File menu drops the Resume item entirely in that overlap,
        /// so a row without this would show two live ⌘R rows.
        case resumable

        func isMet(in ctx: KeystrokeContext) -> Bool {
            switch self {
            case .absent:
                return !ctx.hasSessions
            case .present:
                return ctx.hasSessions
            case .active:
                return ctx.hasActiveSession
            case .live:
                return ctx.hasActiveSession && !ctx.activeSessionExited
            case .running:
                return ctx.hasActiveSession && ctx.activeSessionRunning
                    && !ctx.activeSessionExited
            case .stopped:
                return ctx.hasActiveSession && ctx.activeSessionExited
            case .resumable:
                return ctx.hasActiveSession && ctx.activeSessionExited
                    && !(ctx.tab == .artifacts && ctx.artifactReaderOpen)
            }
        }

        var conditionText: String {
            switch self {
            case .absent:   return "with no sessions open"
            case .present:  return "with a session in the list"
            case .active:   return "with an active session"
            case .live:     return "with a session that has not exited"
            case .running:  return "with a running session"
            case .stopped:  return "with a stopped session"
            case .resumable:
                return "with a stopped session, unless an artifact is open"
            }
        }
    }

    /// Which terminal pane a row needs, and how firmly.
    ///
    /// `nameable` and `focused` look alike and are not: the font keys and
    /// the buffer commands resolve a pane from the focus *memory* when
    /// nothing holds first responder, so they stay live with the caret in
    /// the find bar; ⌘S and the line-jump keys are answered by a monitor
    /// gated on the pane literally holding it, so they do not.
    enum PaneRequirement: Equatable {
        /// `MenuActions.targetTerminalPane()` can name one — the focused
        /// pane, or the remembered one while the Terminal tab shows.
        case nameable
        /// The caret is in one of the two panes.
        case focused
        /// The caret is in the agent's pane.
        case session
        /// The caret is in the shell pane.
        case shell

        func isMet(in ctx: KeystrokeContext) -> Bool {
            switch self {
            case .nameable:
                return ctx.paneFocused
                    || (ctx.tab == .terminal && ctx.hasActiveSession)
            case .focused: return ctx.paneFocused
            case .session: return ctx.sessionPaneFocused
            case .shell:   return ctx.shellPaneFocused
            }
        }

        var conditionText: String {
            switch self {
            case .nameable: return "with a terminal pane in view"
            case .focused:  return "with the caret in a terminal pane"
            case .session:  return "with the caret in the session pane"
            case .shell:    return "with the caret in the shell pane"
            }
        }
    }

    // MARK: - Evaluation

    /// Usable under this snapshot?
    ///
    /// Dialog entries always answer false, which is honest rather than a
    /// gap: the sheet opens only from the main window, and Galaxy's
    /// dialogs are app-modal, so a dialog's keys are never live at the
    /// moment you are reading about them.
    func isActive(in ctx: KeystrokeContext) -> Bool {
        switch self {
        case .app:
            return true
        case .views(let tabs):
            return tabs.contains(ctx.tab)
        case .viewsWithReader(let tabs):
            return tabs.contains(ctx.tab) && ctx.readerOpen(on: ctx.tab)
        case .viewsWithoutReader(let tabs):
            return tabs.contains(ctx.tab) && !ctx.readerOpen(on: ctx.tab)
        case .ledgerSubTabs(let subTabs):
            return ctx.tab == .ledger
                && subTabs.contains(ctx.ledgerSubTab)
        case .appOffFiles:
            return ctx.tab != .files
        case .sessionOffFiles(let requirement):
            return ctx.tab != .files && requirement.isMet(in: ctx)
        case .filesWithClosed:
            return ctx.tab == .files && ctx.hasClosedFiles
        case .filesWithRows:
            return ctx.tab == .files && ctx.hasMultipleFileRows
        case .innerTabs:
            return ctx.tab.hasInnerTabs
        case .listFocus:
            return ctx.hasListFocus
        case .session(let requirement):
            return requirement.isMet(in: ctx)
        case .pane(let requirement):
            return requirement.isMet(in: ctx)
        case .scrollback:
            return ctx.scrollbackOpen
        case .findBar:
            return ctx.findBarOpen
        case .sessionsPanel(let visible):
            return ctx.sessionsPanelVisible == visible
        case .dialog:
            return false
        }
    }

    /// The same condition in words, for the row's trailing text. Empty
    /// when the binding carries no condition worth stating.
    var conditionText: String {
        switch self {
        case .app:
            return ""
        case .views(let tabs):
            return "in \(Self.name(tabs))"
        case .viewsWithReader(let tabs):
            return "in \(Self.name(tabs)), with \(Self.item(tabs)) open"
        case .viewsWithoutReader(let tabs):
            return "in \(Self.name(tabs)), with no \(Self.item(tabs)) open"
        case .ledgerSubTabs(let subTabs):
            return "in Ledger ▸ \(Self.name(subTabs))"
        case .appOffFiles:
            return "outside the Files tab"
        case .sessionOffFiles(let requirement):
            return "\(requirement.conditionText), outside the Files tab"
        case .filesWithClosed:
            return "on Files, with a closed file to bring back"
        case .filesWithRows:
            return "on Files, with more than one row"
        case .innerTabs:
            return "in a view with inner tabs"
        case .listFocus:
            return "where a list has focus"
        case .session(let requirement):
            return requirement.conditionText
        case .pane(let requirement):
            return requirement.conditionText
        case .scrollback:
            return "with a scrollback open"
        case .findBar:
            return "with the find bar open"
        case .sessionsPanel(let visible):
            return visible
                ? "with the sessions panel showing"
                : "with the sessions panel hidden"
        case .dialog(let name):
            return "in the \(name)"
        }
    }

    /// View names in tab-strip order, so two entries covering the same
    /// surfaces always read the same way round.
    private static func name(_ tabs: Set<SessionTab>) -> String {
        let ordered = SessionTab.allCases.filter { tabs.contains($0) }
        if ordered.count == SessionTab.allCases.count { return "any view" }
        return ordered.map(\.title).joined(separator: ", ")
    }

    /// Sub-tab names in strip order. The raw values are the titles the
    /// Ledger's own tab bar prints, so this cannot drift from it.
    private static func name(_ subTabs: Set<LedgerSubTab>) -> String {
        LedgerSubTab.allCases
            .filter { subTabs.contains($0) }
            .map(\.rawValue)
            .joined(separator: " or ")
    }

    /// What the reader on these views has open, named as a reader would
    /// say it. A view with no reader never reaches here.
    ///
    /// Files is the odd one and needs saying: its "reader" is a selected file
    /// rather than something opened over a list — see `KeystrokeContext`. Left
    /// out, its rows fell to the default and told the reader they needed an
    /// artifact or a snapshot open on the Files tab.
    private static func item(_ tabs: Set<SessionTab>) -> String {
        if tabs == [.files] { return "a file" }
        if tabs == [.artifacts] { return "an artifact" }
        if tabs == [.snapshots] { return "a snapshot" }
        if tabs == [.agents] { return "an agent run" }
        return "an artifact or snapshot"
    }
}

/// A keystroke's text, held symbolically when a setting decides it.
///
/// The symbolic cases exist so the catalog can stay a Foundation-only
/// value and still never contradict Settings: it names *which* binding a
/// row shows, and `KeystrokeBindingResolver` reads the live value at
/// display time.
enum KeystrokeBinding: Equatable {
    /// A fixed keystroke, already formatted for display ("⌘T", "esc").
    case literal(String)
    /// The keystroke that commits text — user-configurable.
    case textEntrySubmit
    /// The keystroke that inserts a newline — user-configurable.
    case textEntryNewline
    /// Hide the sessions panel. Not rebindable, but not fixed either:
    /// the bracket flips with `sidebarPosition`, so a literal would be
    /// wrong for every user who moved the panel to the right.
    case sessionsPanelHide
    /// Show the sessions panel — the flipped twin of the above.
    case sessionsPanelShow
}

/// A group of rows in the sheet, in display order.
enum KeystrokeSection: String, CaseIterable {
    case sessions
    case windowAndViews
    case lists
    case files
    case reader
    case terminal
    case scrollback
    case find
    case textEntry
    case dialogs

    var title: String {
        switch self {
        case .sessions:       return "Sessions"
        case .windowAndViews: return "Window & Views"
        case .lists:          return "Lists"
        case .files:          return "Files"
        case .reader:         return "Reader"
        case .terminal:       return "Terminal & Agent"
        case .scrollback:     return "Scrollback"
        case .find:           return "Find"
        case .textEntry:      return "Text Entry"
        case .dialogs:        return "Dialogs"
        }
    }

    /// The section to scroll to when the sheet opens, so the reader
    /// lands where they already are.
    ///
    /// Innermost surface first: a scrollback sits over a pane, and a
    /// reader over a list, and in both cases the keys the reader is
    /// asking about belong to the thing on top. Timeline answers with
    /// Window & Views because view switching is the only thing that
    /// works there — it is the one surface with no keys of its own.
    static func opening(for ctx: KeystrokeContext) -> KeystrokeSection {
        if ctx.scrollbackOpen { return .scrollback }
        if ctx.readerOpen(on: ctx.tab) { return .reader }
        switch ctx.tab {
        case .terminal:
            return .terminal
        case .agents, .artifacts, .snapshots:
            return .lists
        case .ledger:
            return ctx.hasListFocus ? .lists : .windowAndViews
        case .timeline:
            return .windowAndViews
        // Only reached with nothing open — a file on screen is a reader, caught
        // above. An empty strip's keys are the ones that put something in it.
        case .files:
            return .files
        }
    }
}

/// One documented keystroke.
struct KeystrokeEntry: Equatable {
    let binding: KeystrokeBinding
    let label: String
    let section: KeystrokeSection
    let availability: KeystrokeAvailability
    /// Other words for what this does — searched, never drawn.
    ///
    /// The sheet is asked about concepts rather than labels: a reader
    /// hunting everything to do with stopping a session means the
    /// command that ends it, the one that clears it, and the one that
    /// aborts the agent mid-turn, and only one of those three says
    /// "stop" in its label. These carry the words the label cannot
    /// afford to.
    ///
    /// Not folded into the label because several labels are load-bearing
    /// elsewhere — the File menu's four ⌘W titles have to match the menu
    /// verbatim or the sheet and the menu disagree about the same key —
    /// and because a row has to stay short enough to scan a hundred.
    ///
    /// Written as natural phrases, not keywords: matching is ordered, so
    /// "move to the next session" answers a reader typing that where
    /// "session next move" would not.
    var aliases: String = ""
}
