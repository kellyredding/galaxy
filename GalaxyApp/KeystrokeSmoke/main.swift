import Foundation
import Galactic

// Sandboxed smoke check for the ⌘/ cheat sheet's catalog and its
// availability gates. Runs as its own process — no app, no window, no
// SessionManager — against the real catalog. Run via `make smoke`.
// Exits non-zero if any check fails.
//
// Three tiers, in the order a failure is worth reading:
//
//   1. Authoring invariants. Sloppiness — a row with no label, no
//      aliases, a keystroke documented twice in one place.
//   2. Availability truth tables. Lies. The catalog restates gates that
//      live in MainMenu and in five event monitors, and a wrong
//      `availability:` misleads worse than a missing row does: it draws a
//      key bright where pressing it does nothing, or dim where it works.
//      These are asserted against the *rows*, not against hand-written
//      availability values — the gates are Foundation code the compiler
//      already checks, and what can be wrong is which gate a row was
//      given.
//   3. Concept searches, through Galactic's real matcher. Galaxy's labels
//      are terse menu titles lifted verbatim from the menu bar, so the
//      aliases are what make a row reachable at all — and only the shared
//      matcher and the shared glyph table can decide whether they do.
//
// What this does NOT check: the search *rule* and the glyph *table*. Both
// live in Galactic and are asserted there against one fixture in one
// process. This side links them and asserts Galaxy's own vocabulary
// against them, which is the half that is Galaxy's.
//
// One thing it cannot check, stated plainly: which bracket hides the
// sessions panel. ⇧⌘[ and ⇧⌘] trade places with `sidebarPosition`, so
// those two rows bind symbolically and `KeystrokeBindingResolver` reads
// the live setting — which needs SettingsManager and the whole app. What
// is asserted instead is that both rows exist, that they are symbolic
// rather than spelled out, and that their availability is each other's
// inverse.

var failures = 0

func check(_ name: String, _ body: () throws -> Bool) {
    do {
        if try body() {
            print("PASS  \(name)")
        } else {
            print("FAIL  \(name)")
            failures += 1
        }
    } catch {
        print("FAIL  \(name) — threw: \(error)")
        failures += 1
    }
}

/// A context snapshot with everything quiet unless overridden.
///
/// Defaults are the resting app: Terminal tab on Identifiers, no sessions,
/// nothing focused, no reader, no scrollback, no find bar, sessions panel
/// showing. A check names only the facts it is about, so what it is
/// asserting is what it says.
func ctx(
    tab: SessionTab = .terminal,
    ledgerSubTab: LedgerSubTab = .identifiers,
    hasSessions: Bool = false,
    hasActiveSession: Bool = false,
    activeSessionRunning: Bool = false,
    activeSessionExited: Bool = false,
    sessionsPanelVisible: Bool = true,
    artifactReaderOpen: Bool = false,
    snapshotReaderOpen: Bool = false,
    fileOpen: Bool = false,
    agentRunOpen: Bool = false,
    sessionPaneFocused: Bool = false,
    shellPaneFocused: Bool = false,
    scrollbackOpen: Bool = false,
    findBarOpen: Bool = false
) -> KeystrokeContext {
    KeystrokeContext(
        tab: tab,
        ledgerSubTab: ledgerSubTab,
        hasSessions: hasSessions,
        hasActiveSession: hasActiveSession,
        activeSessionRunning: activeSessionRunning,
        activeSessionExited: activeSessionExited,
        sessionsPanelVisible: sessionsPanelVisible,
        artifactReaderOpen: artifactReaderOpen,
        snapshotReaderOpen: snapshotReaderOpen,
        fileOpen: fileOpen,
        agentRunOpen: agentRunOpen,
        sessionPaneFocused: sessionPaneFocused,
        shellPaneFocused: shellPaneFocused,
        scrollbackOpen: scrollbackOpen,
        findBarOpen: findBarOpen)
}

/// The availability of the one row carrying this literal keystroke under
/// this label.
///
/// Looking the row up rather than naming its gate is the point of tier 2:
/// `KeystrokeAvailability.isActive` is Foundation code the compiler
/// already checks, and what can actually be wrong is which case a row was
/// handed. A miss fails here and returns a never-active stand-in, so the
/// caller fails too rather than quietly asserting nothing.
func gate(_ keys: String, _ label: String) -> KeystrokeAvailability {
    rows(where: { $0.binding == .literal(keys) && $0.label == label },
         named: "\(keys) “\(label)”")
}

/// The same, for a row whose keystroke a setting decides.
func gate(
    _ binding: KeystrokeBinding, _ label: String
) -> KeystrokeAvailability {
    rows(where: { $0.binding == binding && $0.label == label },
         named: "\(binding) “\(label)”")
}

private func rows(
    where matches: (KeystrokeEntry) -> Bool, named: String
) -> KeystrokeAvailability {
    let found = KeystrokeCatalog.all.filter(matches)
    guard found.count == 1 else {
        print("FAIL  catalog: expected one row for \(named), "
            + "found \(found.count)")
        failures += 1
        return .dialog("a row that is not in the catalog")
    }
    return found[0].availability
}

/// A stable spelling of an availability, for use as a dictionary key.
///
/// Not `"\(availability)"`: the `.views*` and `.ledgerSubTabs` payloads
/// are `Set`s, whose interpolation order is unspecified — so two identical
/// availabilities can spell differently between runs and the duplicate
/// check would pass or fail at random. Ordering the members pins it, in
/// the same strip order `conditionText` already uses so the key and the
/// row's own words cannot disagree about which set they name.
func availabilityKey(_ a: KeystrokeAvailability) -> String {
    func tabs(_ set: Set<SessionTab>) -> String {
        SessionTab.allCases.filter(set.contains).map(\.rawValue)
            .joined(separator: ",")
    }
    func subs(_ set: Set<LedgerSubTab>) -> String {
        LedgerSubTab.allCases.filter(set.contains).map(\.rawValue)
            .joined(separator: ",")
    }
    switch a {
    case .views(let t):
        return "views(\(tabs(t)))"
    case .viewsWithReader(let t):
        return "viewsWithReader(\(tabs(t)))"
    case .viewsWithoutReader(let t):
        return "viewsWithoutReader(\(tabs(t)))"
    case .ledgerSubTabs(let s):
        return "ledgerSubTabs(\(subs(s)))"
    // Everything else is payload-free or carries an enum or a String, all
    // of which interpolate deterministically.
    default:
        return "\(a)"
    }
}

// MARK: - Tier 1: authoring invariants

// 1. A row with no label is a blank line in the sheet.
check("authoring: every row has a label") {
    KeystrokeCatalog.all.allSatisfy {
        !$0.label.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// 2. Aliases are not optional. A row is invisible to every word its label
// does not use, and Galaxy's labels are the menu bar's own titles —
// "Trim Buffer" answers nothing a reader would type.
check("authoring: every row has aliases") {
    KeystrokeCatalog.all.allSatisfy {
        !$0.aliases.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// 3. The same keystroke twice in one section under the same availability
// is a copy-paste, not a fact. Scoped to the section and the availability
// because Galaxy legitimately documents ⌘=, ⌘W and ↩ more than once —
// each time under a different gate, which is the whole reason the sheet
// has a condition column.
check("authoring: no duplicate keystroke within a section and gate") {
    var seen = Set<String>()
    for entry in KeystrokeCatalog.all {
        let key = "\(entry.section.rawValue)|\(entry.binding)"
            + "|\(availabilityKey(entry.availability))"
        if !seen.insert(key).inserted {
            print("      duplicate: \(key)")
            return false
        }
    }
    return true
}

// 4. A section with no rows draws a bare header — `KeystrokeRows` drops
// it, so the failure is silent: a heading the author expected simply is
// not there.
check("authoring: no empty sections") {
    KeystrokeSection.allCases.allSatisfy { section in
        KeystrokeCatalog.all.contains { $0.section == section }
    }
}

// MARK: - Tier 2: ⌘R, two meanings and a hole

/// The two rows ⌘R can mean. Fetched once: a miss is reported by `gate`
/// itself, so the checks below read as the tables they are.
let refreshArtifact = gate("⌘R", "Refresh artifact")
let resumeSession = gate("⌘R", "Resume session")

// 5. On the Artifacts tab with a document open, ⌘R refreshes the document
// and Resume is not offered — even for a session that has exited and
// could be resumed. buildFileMenu drops the Resume item entirely in that
// state, so a sheet showing both live would be wrong twice.
check("availability: an open artifact takes ⌘R from Resume") {
    let c = ctx(tab: .artifacts, hasSessions: true,
                hasActiveSession: true, activeSessionExited: true,
                artifactReaderOpen: true)
    return refreshArtifact.isActive(in: c)
        && !resumeSession.isActive(in: c)
}

// 6. The tab alone does not take it. With no document open, ⌘R is Resume
// again — the gate is the reader, not the Artifacts tab.
check("availability: the artifacts tab alone does not take ⌘R") {
    let c = ctx(tab: .artifacts, hasSessions: true,
                hasActiveSession: true, activeSessionExited: true)
    return !refreshArtifact.isActive(in: c)
        && resumeSession.isActive(in: c)
}

// 7. The third state: with a running session and no document, ⌘R means
// nothing at all. Neither row is live, and the sheet has to show both
// dimmed rather than pick one — the state a two-way reading of this key
// gets wrong.
check("availability: ⌘R is unbound with a running session") {
    let c = ctx(hasSessions: true, hasActiveSession: true,
                activeSessionRunning: true)
    return !refreshArtifact.isActive(in: c)
        && !resumeSession.isActive(in: c)
}

// 8. The invariant behind all three, asserted over the product rather
// than by row count so the catalog can grow: ⌘R never means two things at
// once.
check("availability: ⌘R's two meanings are never both live") {
    for tab in SessionTab.allCases {
        for readerOpen in [false, true] {
            for exited in [false, true] {
                for active in [false, true] {
                    let c = ctx(
                        tab: tab, hasSessions: active,
                        hasActiveSession: active,
                        activeSessionRunning: active && !exited,
                        activeSessionExited: active && exited,
                        artifactReaderOpen: readerOpen)
                    if refreshArtifact.isActive(in: c),
                       resumeSession.isActive(in: c) {
                        print("      both live: \(tab), reader "
                            + "\(readerOpen), exited \(exited)")
                        return false
                    }
                }
            }
        }
    }
    return true
}

// MARK: - Tier 2: the ⌘W family

/// The five states ⌘W can find the app in, and no others: an active
/// session implies at least one session exists, so the two flags are not
/// independent and a product over them would assert nonsense.
///
/// No pane focused in any of them — the shell-pane meaning is a separate
/// axis, and check 11 is where it is asserted.
let wStates: [(String, KeystrokeContext)] = [
    ("no sessions at all", ctx()),
    ("sessions, none active", ctx(hasSessions: true)),
    ("active, starting", ctx(hasSessions: true,
                            hasActiveSession: true)),
    ("active, running", ctx(hasSessions: true,
                           hasActiveSession: true,
                           activeSessionRunning: true)),
    ("active, exited", ctx(hasSessions: true,
                          hasActiveSession: true,
                          activeSessionExited: true)),
]

/// The three meanings the File menu gives the bare chord.
let wFileMenu = [
    ("Stop session", gate("⌘W", "Stop session")),
    ("Dismiss session", gate("⌘W", "Dismiss session")),
    ("Close window", gate("⌘W", "Close window")),
]

// 9. Never two at once, in any of the five states. Three meanings over
// five states, and Stop covers both "starting" and "running" — which is
// why the running flag alone cannot drive that row.
check("availability: ⌘W never means two things at once") {
    for (name, c) in wStates {
        let live = wFileMenu.filter { $0.1.isActive(in: c) }
        if live.count > 1 {
            print("      \(name): \(live.map(\.0))")
            return false
        }
    }
    return true
}

// 10. And the fourth state is the one with nothing to say. Sessions in
// the list but none active leaves all three dark, which is honest: the
// File menu keeps a disabled placeholder there, and a disabled item has
// no keystroke to document. Every other state has exactly one meaning.
check("availability: ⌘W is silent only with sessions and none active") {
    for (name, c) in wStates {
        let live = wFileMenu.filter { $0.1.isActive(in: c) }.count
        let expected = (c.hasSessions && !c.hasActiveSession) ? 0 : 1
        if live != expected {
            print("      \(name): \(live) live, expected \(expected)")
            return false
        }
    }
    return true
}

// 11. The fifth meaning, and the one that wins: a pre-menu NSEvent
// monitor takes ⌘W for a focused shell pane before the File menu is
// consulted at all. Its own axis — dark in every state above, live
// whenever the caret is in the shell and never when it is in the session
// pane, so the row cannot be read as "there is a shell open".
check("availability: ⌘W's shell meaning follows the caret alone") {
    let shellPane = gate("⌘W", "Close the focused shell pane")
    let darkWithoutFocus = wStates.allSatisfy {
        !shellPane.isActive(in: $0.1)
    }
    return darkWithoutFocus
        && shellPane.isActive(in: ctx(hasSessions: true,
                                      hasActiveSession: true,
                                      activeSessionRunning: true,
                                      shellPaneFocused: true))
        && !shellPane.isActive(in: ctx(hasSessions: true,
                                       hasActiveSession: true,
                                       activeSessionRunning: true,
                                       sessionPaneFocused: true))
}

// 12. ⌘W never closes the window while any session exists — the fact
// that surprises people, and the reason ⇧⌘W exists and stays live in all
// five states.
check("availability: ⌘W closes the window only with no sessions") {
    let closeOnW = gate("⌘W", "Close window")
    let shiftCloseWindow = gate("⇧⌘W", "Close window")
    return wStates.allSatisfy { _, c in
        closeOnW.isActive(in: c) == !c.hasSessions
            && shiftCloseWindow.isActive(in: c)
    }
}

// MARK: - Tier 2: list focus, and Open

/// Every surface Galaxy has: seven views, and the Ledger's five sub-tabs
/// within one of them. Eleven distinct surfaces, and every one answers ↩
/// differently.
let surfaces: [(SessionTab, LedgerSubTab)] = SessionTab.allCases
    .flatMap { tab in LedgerSubTab.allCases.map { (tab, $0) } }

/// The five rows ↩ can be, one per surface that opens something.
let openRows = [
    ("Open snapshot", gate("↩", "Open snapshot")),
    ("Open artifact", gate("↩", "Open artifact")),
    ("Open agent run", gate("↩", "Open agent run")),
    ("Reveal file in Finder", gate("↩", "Reveal file in Finder")),
    ("Open entry", gate("↩", "Open entry")),
]

// 13. `hasListFocus` restates a gate that buildViewMenu holds as a local
// `let` with no name to call, so nothing makes the two agree. Written out
// here independently — not through `KeystrokeCatalog.ledgerListSubTabs` —
// so this is a second opinion rather than a tautology.
check("availability: list nav is live on exactly six of eleven surfaces") {
    let listNav = gate("⌘J", "Next item")
    for (tab, sub) in surfaces {
        let expected: Bool
        switch tab {
        case .snapshots, .artifacts, .agents:
            expected = true
        case .ledger:
            expected = sub == .fileAccess || sub == .entries
        // Files has a strip, not a list: ⌘J/K step rows within the strip as an
        // inner-tab axis, which is a different pair of keys from list nav.
        case .terminal, .timeline, .files:
            expected = false
        }
        let live = listNav.isActive(in: ctx(tab: tab, ledgerSubTab: sub))
        if live != expected {
            print("      \(tab)/\(sub): \(live), expected \(expected)")
            return false
        }
    }
    return true
}

// 14. The drift detector. `hasListFocus` and
// `openFocusedItemDescriptor` are two separate switches over the same tab
// set, written 500 lines apart. With nothing open over the list they must
// agree on every one of the ten surfaces — and Open must resolve to
// exactly one row where it is live, since two live ↩ rows would be two
// commands claiming one key.
check("availability: list nav and Open agree on every surface") {
    let listNav = gate("⌘J", "Next item")
    for (tab, sub) in surfaces {
        let c = ctx(tab: tab, ledgerSubTab: sub)
        let nav = listNav.isActive(in: c)
        let open = openRows.filter { $0.1.isActive(in: c) }
        if nav != (open.count == 1) {
            print("      \(tab)/\(sub): nav \(nav), open "
                + "\(open.map(\.0))")
            return false
        }
    }
    return true
}

// 15. And the one place they diverge, which is not drift but the rule: an
// open reader keeps ⌘J/K moving the list behind it while ↩ stops opening
// anything, because the thing ↩ would open is already on screen.
check("availability: an open reader keeps list nav, drops Open") {
    let listNav = gate("⌘J", "Next item")
    let states = [
        ctx(tab: .artifacts, artifactReaderOpen: true),
        ctx(tab: .snapshots, snapshotReaderOpen: true),
    ]
    return states.allSatisfy { c in
        listNav.isActive(in: c)
            && openRows.allSatisfy { !$0.1.isActive(in: c) }
    }
}

// MARK: - Tier 2: the reader pairs

// 16. `.viewsWithReader` and `.viewsWithoutReader` are exact complements
// within the tab they name, and dark on every other tab. Asserted as the
// complement rather than row by row, because the drift this pair invites
// is one half being widened without the other.
check("availability: the reader pair is a complement within its tab") {
    let pairs: [(String, SessionTab, KeystrokeAvailability,
                 KeystrokeAvailability)] = [
        ("artifacts", .artifacts,
         gate("⌘R", "Refresh artifact"), gate("↩", "Open artifact")),
        ("snapshots", .snapshots,
         gate("⌘F", "Find in the open snapshot"),
         gate("↩", "Open snapshot")),
    ]
    for (name, own, withReader, withoutReader) in pairs {
        for tab in SessionTab.allCases {
            for open in [false, true] {
                let c = ctx(
                    tab: tab,
                    artifactReaderOpen: own == .artifacts && open,
                    snapshotReaderOpen: own == .snapshots && open)
                let w = withReader.isActive(in: c)
                let wo = withoutReader.isActive(in: c)
                let onOwnTab = tab == own
                if w != (onOwnTab && open) || wo != (onOwnTab && !open) {
                    print("      \(name) on \(tab), open \(open): "
                        + "with \(w), without \(wo)")
                    return false
                }
            }
        }
    }
    return true
}

// 17. Cross-tab staleness. Both reader flags are global on SessionManager
// while being set by per-session views, so either can still be true for a
// tab the user has left — and a gate that read the flag without pairing
// it to its own tab would light up on the wrong surface. This is the one
// the manual QA script's step 4 checks by hand.
check("availability: a reader left open elsewhere lights nothing here") {
    let artifactZoom = gate("⌘R", "Refresh artifact")
    let snapshotFind = gate("⌘F", "Find in the open snapshot")
    let agentEscape = gate("esc", "Close the agent run")
    return !artifactZoom.isActive(
        in: ctx(tab: .snapshots, artifactReaderOpen: true))
        && !snapshotFind.isActive(
            in: ctx(tab: .artifacts, snapshotReaderOpen: true))
        // The Agents tab's detail is not a web view, but it answers the
        // same question a reader does — and `AgentsView` installs its
        // Escape monitor only while a run is selected, so without the
        // second half this row reads live on an empty Agents list where
        // Escape does nothing at all.
        && agentEscape.isActive(in: ctx(tab: .agents, agentRunOpen: true))
        && !agentEscape.isActive(in: ctx(tab: .agents))
        && !agentEscape.isActive(
            in: ctx(tab: .agents, artifactReaderOpen: true,
                    snapshotReaderOpen: true))
}

// 18. The two ⌘= rows never read live together. A reader web view in the
// window claims exactly-Command over =, -, and 0 in
// `performKeyEquivalent`, so on a reader tab the terminal-font row is a
// key the menu never sees — and `.pane(.nameable)` is what keeps it dark
// there, because `targetTerminalPane()` names nothing with the web view
// holding focus. The terminal row stays live with the find bar up, which
// is the near-miss the pane-focus memory exists for.
check("availability: reader zoom and terminal font never both light") {
    let documentZoom = gate("⌘=", "Zoom the document in")
    let terminalZoom = gate("⌘=", "Bigger terminal font size")
    let onReader = ctx(tab: .artifacts, hasSessions: true,
                       hasActiveSession: true,
                       activeSessionRunning: true,
                       artifactReaderOpen: true)
    let onTerminalWithFind = ctx(hasSessions: true,
                                 hasActiveSession: true,
                                 activeSessionRunning: true,
                                 findBarOpen: true)
    return documentZoom.isActive(in: onReader)
        && !terminalZoom.isActive(in: onReader)
        && terminalZoom.isActive(in: onTerminalWithFind)
        && !documentZoom.isActive(in: onTerminalWithFind)
}

// MARK: - Tier 2: the sessions-panel pair

// 19. Both rows exist and neither spells its keystroke out. The letters
// trade places with `sidebarPosition`, so a literal would be wrong for
// every user who moved the panel to the right — and resolving the
// symbolic form needs SettingsManager, which is deliberately outside this
// tool. That both rows are symbolic is the half that is assertable, and
// it is the half that goes wrong.
check("keys: the sessions-panel pair binds symbolically") {
    let pair = KeystrokeCatalog.all.filter {
        $0.label == "Hide sessions" || $0.label == "Show sessions"
    }
    guard pair.count == 2 else {
        print("      \(pair.count) rows, expected 2")
        return false
    }
    return pair.allSatisfy { entry in
        switch entry.binding {
        case .sessionsPanelHide, .sessionsPanelShow: return true
        default: return false
        }
    }
}

// 20. And their availability is each other's inverse, in both panel
// positions. Crossed axes: the letters follow the side, the enable state
// follows visibility — and a row that mixed them up would read plausibly
// in the position it was authored in and lie in the other. Exactly one of
// the pair is live at any moment, because the shortcut the user just used
// has to go dark and its inverse come live.
check("availability: the sessions-panel pair is its own inverse") {
    let hide = gate(.sessionsPanelHide, "Hide sessions")
    let show = gate(.sessionsPanelShow, "Show sessions")
    for visible in [true, false] {
        let c = ctx(sessionsPanelVisible: visible)
        if hide.isActive(in: c) != visible { return false }
        if show.isActive(in: c) == visible { return false }
    }
    return true
}

// 21. Every Scrollback row is gated on a scrollback being open, and none
// of them is live without one.
//
// What this cannot reach, said plainly: which *pane* the snapshot asked
// about. That answer is assembled in `KeystrokeSheetModel`, which links
// Galactic and so is not in this target — and it is where this section was
// wrong for a shell scrollback, reading a flag that only ever described the
// agent's pane. What is checkable from here is that the rows depend on the
// answer at all, so a future edit cannot quietly hand one of them `.app`.
check("availability: no Scrollback row is live without a scrollback") {
    let rows = KeystrokeCatalog.all.filter { $0.section == .scrollback }
    if rows.isEmpty { return false }
    let closed = ctx(scrollbackOpen: false)
    let open = ctx(sessionPaneFocused: true, scrollbackOpen: true)
    return rows.allSatisfy { !$0.availability.isActive(in: closed) }
        && rows.contains { $0.availability.isActive(in: open) }
}

// MARK: - Tier 3: concept searches

/// The real catalog as search candidates, composed exactly as
/// `CheatSheetView` composes them — aliases first, then the row's own
/// glyphs spelled out, joined by one space. That order is load-bearing:
/// `.terms` matching requires terms to appear in order within a field, so
/// reversing the join changes which multi-term queries match.
///
/// Literal keystrokes only. Resolving a rebindable or a symbolic one needs
/// SettingsManager, which this target deliberately cannot see; those rows
/// searching as if unbound costs nothing the checks below assert.
func catalogCandidates() -> [CheatSheetSearch.Candidate] {
    KeystrokeCatalog.all.map { entry in
        var keys = ""
        if case .literal(let text) = entry.binding { keys = text }
        return CheatSheetSearch.Candidate(
            label: entry.label,
            keys: keys,
            section: entry.section.title,
            condition: entry.availability.conditionText,
            aliases: entry.aliases + " " + CheatSheetGlyphs.spelled(keys))
    }
}

/// The labels a query keeps, in catalog order and with duplicates intact —
/// several labels appear more than once under different keys.
func catalogMatches(_ query: String) -> [String] {
    zip(
        KeystrokeCatalog.all,
        CheatSheetSearch.hits(catalogCandidates(), query: query)
    ).compactMap { $1 == nil ? nil : $0.label }
}

// 21. The helper above zips the catalog against the hits, so an array
// that is not index-aligned would silently shorten the corpus and every
// check after it would pass over a prefix. Asserted rather than trusted:
// alignment is Galactic's contract, and this is Galaxy's only handhold on
// it.
check("search: hits stay index-aligned with the catalog") {
    CheatSheetSearch.hits(catalogCandidates(), query: "session").count
        == KeystrokeCatalog.all.count
}

// 22. A phrase a reader would actually type reaches the row that answers
// it, and stays inside the section that owns the concept.
//
// Reaching the row is the assertion; the section is the narrowness a
// phrase query can honestly be held to. A space in the query stands in
// for `.+`, so over a field as long as an alias list the three terms may
// legitimately span several synonyms — which is exactly how Dismiss and
// Resume come along ("a **stop**ped session … **the** sidebar … a
// finished **session**"). Three ⌘W/⌘R lifecycle rows is a fair answer to
// that question; a row from Reader or Dialogs would not be.
//
// This is also why the aliases are written as natural phrases rather than
// keyword soup: "session stop shut" would answer nothing at all.
check("search: “stop the session” reaches the key that stops it") {
    let kept = zip(
        KeystrokeCatalog.all,
        CheatSheetSearch.hits(catalogCandidates(),
                              query: "stop the session")
    ).compactMap { $1 == nil ? nil : $0 }
    return kept.contains { $0.label == "Stop session" }
        && kept.allSatisfy { $0.section == .sessions }
}

// 23. A concept answers with everything that ends a turn or a session,
// not just the row whose label happens to say so. Only one of these three
// says "stop" anywhere in its label; the other two reach it through
// aliases alone, which is the entire reason that field exists.
check("search: “stop” reaches every way to stop something") {
    Set(catalogMatches("stop")).isSuperset(of: [
        "Stop session",                 // ends the session
        "Interrupt the agent's turn",   // aborts the turn mid-answer
        "Dismiss the find bar",         // stops searching
    ])
}

// 24. A thing answers in both directions. Before aliases, "sessions
// panel" found neither row: one says "Hide sessions" and the other "Show
// sessions", and the word "panel" is in neither label.
check("search: the sessions panel answers both ways round") {
    Set(catalogMatches("sessions panel"))
        == ["Hide sessions", "Show sessions"]
}

// 25. The glyph table doing its job. None of ⌫, ⇞, ⇟ can be typed into
// the search field, so without the spelled-out names these rows are
// unreachable by search entirely — and ⌫ spelling itself "backspace"
// rather than "delete" is what keeps two destructive session commands out
// of every search for "delete".
check("search: glyphs answer to the words readers type") {
    Set(catalogMatches("backspace")) == ["Clear session",
                                         "Compact session"]
        && !Set(catalogMatches("delete")).contains("Clear session")
        && Set(catalogMatches("page up")) == ["Page up"]
        && Set(catalogMatches("page down")) == ["Page down"]
}

/// Characters Galaxy's catalog puts on a row that `CheatSheetGlyphs` has
/// no words for, and so cannot be reached by typing a name.
///
/// Declared rather than tolerated, and the bar for adding one is high: a
/// character that names a key belongs in the shared table, because every
/// host binding that key wants the same word. This list is for characters
/// that are not keys at all.
///
/// It held `[`, `]` and `?` until the shared table learned them. Those
/// three were keys, so declaring them here was the wrong side of that
/// line — the rows survived on their aliases and a reader typing "bracket"
/// still found nothing.
let unspellableGlyphs: Set<Character> = [
    // The range in "⌘1…⌘9" — punctuation in an expression, not a key
    // anyone presses. The row is reached by "session" and by the digits
    // themselves, which are typed as themselves.
    "…",
]

// 26. A tripwire on the glyph inventory, not a copy of the spelling
// table. The mapping from ⌘ to "command cmd" is Galactic's and is
// asserted there; what Galaxy owns is the set of glyphs its catalog puts
// on a row. Introducing an unnamed one makes that row unreachable by
// search the moment it lands, and nothing else notices — the row renders
// perfectly.
check("search: every glyph is nameable, or declared and reachable") {
    var undeclared: [String] = []
    for entry in KeystrokeCatalog.all {
        guard case .literal(let keys) = entry.binding else { continue }
        // Letters and digits are not glyphs; they are typed as
        // themselves.
        for glyph in keys
        where !glyph.isLetter && !glyph.isNumber && !glyph.isWhitespace
            && CheatSheetGlyphs.spelled(String(glyph)).isEmpty
            && !unspellableGlyphs.contains(glyph) {
            undeclared.append("\(keys) “\(entry.label)”: \(glyph)")
        }
    }
    for line in undeclared { print("      no name for \(line)") }
    // Named is not the same as reachable, so the three that most recently
    // gained names are followed all the way through the catalog to the
    // rows they should land on. "bracket" reaches only the pair that
    // renders one: the sessions-panel rows bind symbolically and resolve
    // to nothing in this target, which is the same blind spot assist-ant's
    // smoke has and for the same reason.
    return undeclared.isEmpty
        && Set(catalogMatches("bracket")) == ["Back", "Forward"]
        && Set(catalogMatches("question mark")) == ["Galaxy Help"]
        // And the authored aliases still carry the concepts, which is what
        // a reader reaches for before they think about characters.
        && Set(catalogMatches("navigation history")) == ["Back", "Forward"]
        && Set(catalogMatches("help book")) == ["Galaxy Help"]
}

// 27. And the corpus stays narrow. A row survives a query only when one
// of its five searchable fields actually spells it — the property that
// broke when the matcher read a whole row as one gap-anywhere
// subsequence, and the reason a search for a typo now answers nothing
// rather than answering wrongly.
check("search: a word query stays narrow over the real catalog") {
    let candidates = catalogCandidates()
    let hits = CheatSheetSearch.hits(candidates, query: "annotation")
    let kept = zip(candidates, hits).compactMap { $1 == nil ? nil : $0 }
    return !kept.isEmpty && kept.allSatisfy { candidate in
        [candidate.label, candidate.keys, candidate.section,
         candidate.condition, candidate.aliases]
            .contains { $0.lowercased().contains("annotation") }
    }
}

print(failures == 0
    ? "\n✅ all smoke checks passed"
    : "\n❌ \(failures) smoke check(s) failed")
exit(failures == 0 ? 0 : 1)
