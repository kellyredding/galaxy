import AppKit
import Foundation
import Galactic

/// The one place Galaxy reads live app state into a `KeystrokeContext`.
///
/// A namespace rather than an `ObservableObject`: this is assist-ant's
/// side of the ⌘/ sheet minus the presentation state, which
/// `CheatSheetPresenter` now owns. Nothing here is observed, and nothing
/// here is held — the context lives for the length of one call.
///
/// Named for assist-ant's file rather than its type. That app folded its
/// snapshot and its rows builder into one `KeystrokeSheet.swift` when the
/// mechanism moved into Galactic; Galaxy keeps them apart because its
/// snapshot is fourteen fields against assist-ant's six, and a single file
/// would bury the builder under it. Same directory, same shape, one file
/// more.
@MainActor
enum KeystrokeSheetModel {

    /// Registered on `CheatSheetPresenter` at launch, invoked once per
    /// present. That is what keeps the snapshot honest: the sheet's own
    /// search field takes first responder as the overlay mounts, and the
    /// mount is a SwiftUI update pass later than this call — so the focus
    /// questions below still describe the surface *behind* the sheet. Read
    /// live, the pane-focus fields would answer for the sheet.
    static func sections() -> [CheatSheetSection] {
        KeystrokeRows.sections(for: captureContext())
    }

    /// Read the surface the user is looking at.
    ///
    /// Focus questions are delegated to `MenuActions`, which already
    /// answers them for menu validation — asking the same question two
    /// ways is how the sheet comes to disagree with which commands are
    /// actually live.
    ///
    /// Note what is *not* asked here: whether a terminal pane can be
    /// *named*. `KeystrokeAvailability.PaneRequirement.nameable` derives
    /// that from `paneFocused`, the tab, and an active session — the same
    /// three facts `MenuActions.targetTerminalPane()` composes — so the
    /// snapshot carries the facts and the gate does the composing. One
    /// answer recorded twice is the thing a snapshot is for; one answer
    /// recorded once and derived twice is not.
    static func captureContext() -> KeystrokeContext {
        let sm = SessionManager.shared
        let session = sm.activeSession
        // One responder walk, two fields. Asking twice would walk the
        // view tree twice and could — in principle — answer differently
        // either side of the second call.
        let focusedPane = MenuActions.focusedPaneKind()
        return KeystrokeContext(
            tab: sm.activeTab,
            ledgerSubTab: sm.activeLedgerSubTab,
            hasSessions: !sm.sessions.isEmpty,
            hasActiveSession: session != nil,
            // Three states, not two: a session that exists and has not
            // exited is not necessarily running (resume clears both
            // flags). ⌘W says "Stop session" in that window; Clear and
            // Compact are not offered.
            activeSessionRunning:
                session.map { $0.isRunning && !$0.hasExited } ?? false,
            activeSessionExited: session?.hasExited ?? false,
            // `SidebarPreferences`, not `AppSettings.isSidebarVisible` —
            // the narrow publisher `validateMenuItem` gates Hide / Show
            // on. The settings value only seeds it at launch and is
            // written back a runloop later, so a sheet opened in that
            // window would disagree with the menu.
            //
            // And `isVisible` rather than `preferredVisible`: the sheet
            // says what the key will do, which is a fact about the panel
            // on screen and not about the choice behind it.
            sessionsPanelVisible: SidebarPreferences.shared.isVisible,
            // Global flags set by per-session views, so either can be
            // true for a tab you are no longer on. Every gate that reads
            // one pairs it with its own tab.
            artifactReaderOpen: sm.isArtifactReaderOpen,
            snapshotReaderOpen: sm.isSnapshotReaderOpen,
            // Per-session and read from the session rather than from a global,
            // like the agent selection below and unlike the two readers above:
            // the strip belongs to a session, so there is no app-wide flag that
            // could be stale for the tab you are on.
            fileOpen: session?.selectedFilePath != nil,
            // `AgentsView` keeps the selection in `@State` and mirrors it
            // onto the session, which is the only readable copy from out
            // here — and it is the same fact the view's own Escape
            // monitor is gated on, so the row and the monitor agree.
            agentRunOpen: session?.selectedAgentId != nil,
            sessionPaneFocused: focusedPane == .session,
            shellPaneFocused: focusedPane == .shell,
            // The pane the caret is in, not "any pane" — a scrollback open on
            // the pane beside the one being typed in does not make these keys
            // live. With no pane focused there is nothing to be reading, so
            // neither is any scrollback the sheet should describe.
            scrollbackOpen: focusedPane.map {
                session?.paneRegistry.scrollbackOpenKinds.contains($0) ?? false
            } ?? false,
            findBarOpen: FindBarPanelController.shared.isPresenting
        )
    }

    /// The cheat sheet's stand-down gate, in one spelling.
    ///
    /// `nonisolated` because every caller is a local `NSEvent` monitor
    /// closure or a menu-validation call, and AppKit declares neither
    /// main-actor even though both run there. `assumeIsolated` states that
    /// rather than hopping: a monitor answering a runloop turn late has
    /// already let the key through.
    ///
    /// Where assist-ant reads `CheatSheetPresenter.isClaimingKeyboard`
    /// directly at all six of its sites, Galaxy cannot: one of its five is
    /// inside a plain `NSObject`'s escaping closure, where the compiler
    /// correctly objects to reaching main-actor state. One accessor rather
    /// than five, so the isolation is stated once and every guard below
    /// reads the same.
    /// Now asks about every Galactic-owned modal rather than the cheat sheet
    /// alone. A second one shipped, and each of the five guards below would
    /// otherwise have kept answering keys behind it — silently, since a
    /// keystroke that does the wrong thing reports nothing.
    nonisolated static var isClaimingKeyboard: Bool {
        MainActor.assumeIsolated {
            GalacticModals.isClaimingKeyboard
        }
    }
}
