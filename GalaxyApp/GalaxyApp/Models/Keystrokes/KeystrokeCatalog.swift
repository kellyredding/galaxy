import Foundation

/// Every keystroke Galaxy answers to, hand-authored.
///
/// A second statement of facts that already live in `MainMenu`,
/// `ShellCloseKeyMonitor`, the escape monitors in `ArtifactsView`,
/// `SnapshotsView` and `AgentsView`, `RestoreSessionSheetController`,
/// `PreferencesWindowController`, and Galactic's `ReaderWebView`,
/// `ScrollbackHTMLRenderer`, `SendBarJS`, `FindBarView` and
/// `TerminalHostView` — so it can drift from all of them. That is
/// accepted knowingly. Two thirds of these bindings are not menu items
/// at all: they live inside event monitors and JavaScript keydown
/// switches and cannot be derived, and deriving only the menu half would
/// automate the entries macOS already displays while leaving the
/// valuable ones hand-written anyway.
///
/// Anything a setting decides is named symbolically
/// (`.textEntrySubmit`, `.sessionsPanelHide`) rather than spelled out,
/// so the sheet reads the live value and cannot contradict Settings.
///
/// One keystroke is deliberately absent: `Keystroke.reservedMachineSubmit`
/// (⌃⌥⇧⌘↩), which Galaxy writes into `~/.claude/keybindings.json` for
/// its own automated submissions. The recorder refuses to let a user
/// bind it, and a row would advertise it as something to press — the
/// first thing anyone reading a cheat sheet does.
enum KeystrokeCatalog {

    /// The Ledger sub-tabs that host a focusable list. Named once here
    /// because three switches ask the question — this one, `MainMenu`'s
    /// `hasListFocus`, and `openFocusedItemDescriptor`.
    static let ledgerListSubTabs: Set<LedgerSubTab> = [.files, .entries]

    /// Both readers, for the rows whose keys mean the same thing in
    /// either one.
    private static let readerViews: Set<SessionTab> = [.artifacts, .snapshots]

    /// Built by appending rather than one `+` chain: nine concatenated
    /// array literals push the type-checker past its budget and fail to
    /// compile. assist-ant found that the hard way with the same shape.
    ///
    /// A stored constant, exactly as assist-ant's is — including for the
    /// one row where that looks impossible. ⇧⌘[ and ⇧⌘] trade places with
    /// the sessions panel, so which bracket hides it depends on a setting;
    /// those two rows therefore bind symbolically
    /// (`.sessionsPanelHide` / `.sessionsPanelShow`) and
    /// `KeystrokeBindingResolver` reads the position live, which is the
    /// same seam every other setting-dependent row already uses. Making
    /// the catalog a function of the surface instead would move one
    /// settings read out of the resolver and into the snapshot, splitting
    /// across two places what belongs in one.
    static let all: [KeystrokeEntry] = {
        var out: [KeystrokeEntry] = []
        out += sessions
        out += windowAndViews
        out += lists
        out += reader
        out += terminal
        out += scrollback
        out += find
        out += textEntry
        out += dialogs
        return out
    }()

    // MARK: - Sessions

    /// A session is Galaxy's central object, so this section leads —
    /// where assist-ant's sheet opens on the global hotkeys it has and
    /// this app does not.
    ///
    /// The four ⌘W titles and the two ⌘R titles are the File menu's
    /// verbatim, and must stay so: a reader comparing the sheet to the
    /// menu is comparing the same key, and two wordings for one command
    /// reads as two commands.
    private static let sessions: [KeystrokeEntry] = [
        .init(binding: .literal("⌘N"), label: "New Session...",
              section: .sessions, availability: .app,
              aliases: "start a session, create a session, launch claude, "
                  + "new agent, add a session"),
        .init(binding: .literal("⇧⌘N"), label: "New Marker...",
              section: .sessions, availability: .app,
              aliases: "add a marker, label the sidebar, divider, "
                  + "separator, group the sessions"),
        .init(binding: .literal("⇧⌘T"), label: "Restore Session...",
              section: .sessions, availability: .app,
              aliases: "reopen a closed session, bring back a session, "
                  + "open a past session, the closed session archive, "
                  + "undo closing a session"),

        // One row for nine keys. The menu builds an item per session, so
        // the ninth exists only with nine sessions open — but a row per
        // session would be a sheet that changes length as you work, and
        // the thing being documented is the range.
        .init(binding: .literal("⌘1…⌘9"),
              label: "Switch to session 1–9",
              section: .sessions,
              availability: .session(.present),
              aliases: "jump to a session, go to a session by number, "
                  + "pick a session from the list"),

        // `.active`, not `.present`: `canSwitchToPreviousSession` guards
        // on `activeSessionId` before it looks at the list at all, so
        // both keys are dead in the state where sessions exist and none
        // is active. The rest of that gate — more than one session, and
        // not already at the end of the list — is a "nowhere left to go"
        // and stays unmodelled, for the reason `.app` gives.
        //
        // The arrow twins are `isAlternate` items on one command, and get
        // their own rows for the same reason assist-ant writes ⌘H and ⌘←
        // twice: a row is one keystroke, and stacking two into one cell
        // blows out a column every other row aligns to.
        .init(binding: .literal("⇧⌘K"), label: "Previous session",
              section: .sessions, availability: .session(.active),
              aliases: "move up the session list, the session above, "
                  + "earlier session, back up the sidebar"),
        .init(binding: .literal("⇧⌘↑"), label: "Previous session",
              section: .sessions, availability: .session(.active),
              aliases: "move up the session list, the session above, "
                  + "earlier session, back up the sidebar"),
        .init(binding: .literal("⇧⌘J"), label: "Next session",
              section: .sessions, availability: .session(.active),
              aliases: "move down the session list, the session below, "
                  + "later session, on down the sidebar"),
        .init(binding: .literal("⇧⌘↓"), label: "Next session",
              section: .sessions, availability: .session(.active),
              aliases: "move down the session list, the session below, "
                  + "later session, on down the sidebar"),

        // ⌘W's second, third and fifth meanings. The first belongs to a
        // pre-menu event monitor and is documented in Terminal & Agent;
        // the fourth is a disabled placeholder and has no row.
        //
        // The lead alias is the phrase itself, spelled out. Matching is
        // ordered and each term is contiguous, so "stop the session" only
        // reaches a row that says those three words in that order — and
        // the label says two of them with nothing in between.
        .init(binding: .literal("⌘W"), label: "Stop session",
              section: .sessions, availability: .session(.live),
              aliases: "stop the session, end the session, kill the "
                  + "agent, quit claude, halt the session, shut the "
                  + "session down"),
        .init(binding: .literal("⌘W"), label: "Dismiss session",
              section: .sessions, availability: .session(.stopped),
              aliases: "remove a stopped session, clear it out of the "
                  + "sidebar, get rid of a finished session"),
        // The condition has to name the suppression, not just the state:
        // with an artifact open the File menu drops this item entirely
        // and ⌘R refreshes instead.
        .init(binding: .literal("⌘R"), label: "Resume session",
              section: .sessions, availability: .session(.resumable),
              aliases: "restart a stopped session, continue the session, "
                  + "pick the session back up, bring the agent back"),

        .init(binding: .literal("⇧⌘⌫"), label: "Clear session",
              section: .sessions, availability: .session(.running),
              aliases: "wipe the transcript, reset the context, "
                  + "clear the screen, start the conversation over"),
        .init(binding: .literal("⌃⌘⌫"), label: "Compact session",
              section: .sessions, availability: .session(.running),
              aliases: "summarise the context, condense the transcript, "
                  + "shrink the context, free up context"),

        // Symbolic, not literal. The bracket flips with
        // `sidebarPosition` — ⇧⌘[ means "toward the panel" — so a
        // spelled-out key would be wrong for every user who moved the
        // panel to the right.
        .init(binding: .sessionsPanelHide, label: "Hide sessions",
              section: .sessions,
              availability: .sessionsPanel(visible: true),
              aliases: "close the sessions panel, collapse the sidebar, "
                  + "hide the sidebar, make room for the view"),
        .init(binding: .sessionsPanelShow, label: "Show sessions",
              section: .sessions,
              availability: .sessionsPanel(visible: false),
              aliases: "open the sessions panel, expand the sidebar, "
                  + "show the sidebar, bring the session list back"),
    ]

    // MARK: - Window & views

    /// A view is a tab everywhere except in this app's own vocabulary,
    /// so every row that switches one carries the other word — and the
    /// inner pair has to say *inner*, because otherwise the two pairs
    /// are four rows answering to "tab" with no way to tell them apart.
    private static let windowAndViews: [KeystrokeEntry] = [
        .init(binding: .literal("⇧⌘H"), label: "Previous view",
              section: .windowAndViews, availability: .app,
              aliases: "previous tab, switch tabs, change view, "
                  + "move left along the tab strip"),
        .init(binding: .literal("⇧⌘←"), label: "Previous view",
              section: .windowAndViews, availability: .app,
              aliases: "previous tab, switch tabs, change view, "
                  + "move left along the tab strip"),
        .init(binding: .literal("⇧⌘L"), label: "Next view",
              section: .windowAndViews, availability: .app,
              aliases: "next tab, switch tabs, change view, "
                  + "move right along the tab strip"),
        .init(binding: .literal("⇧⌘→"), label: "Next view",
              section: .windowAndViews, availability: .app,
              aliases: "next tab, switch tabs, change view, "
                  + "move right along the tab strip"),

        .init(binding: .literal("⌘H"), label: "Previous tab",
              section: .windowAndViews, availability: .innerTabs,
              aliases: "previous inner tab, previous ledger tab, "
                  + "move left inside the view"),
        .init(binding: .literal("⌘←"), label: "Previous tab",
              section: .windowAndViews, availability: .innerTabs,
              aliases: "previous inner tab, previous ledger tab, "
                  + "move left inside the view"),
        .init(binding: .literal("⌘L"), label: "Next tab",
              section: .windowAndViews, availability: .innerTabs,
              aliases: "next inner tab, next ledger tab, "
                  + "move right inside the view"),
        .init(binding: .literal("⌘→"), label: "Next tab",
              section: .windowAndViews, availability: .innerTabs,
              aliases: "next inner tab, next ledger tab, "
                  + "move right inside the view"),

        // `.session(.active)` rather than a history-depth gate: the
        // navigation history belongs to the active session
        // (`canNavigateBack` reaches through `activeSession`), so no
        // session is the only state in which these genuinely do
        // nothing. An empty history is a "nowhere to go" and dimming
        // for it would say the key does not exist here.
        .init(binding: .literal("⌘["), label: "Back",
              section: .windowAndViews, availability: .session(.active),
              aliases: "go back, retrace, where i just was, "
                  + "navigation history"),
        .init(binding: .literal("⌘]"), label: "Forward",
              section: .windowAndViews, availability: .session(.active),
              aliases: "go forward, replay the step, "
                  + "navigation history"),

        // Spelled out three times rather than leaning on the menu's
        // "Chrome Font Size" heading — a search strips a row of its
        // neighbours, and a lone "Default" then says nothing about what
        // it resets. Same reasoning as the terminal trio below, and the
        // same deliberate divergence from the menu titles.
        //
        // ⇧⌘ rather than bare ⌘ is also what keeps these working over an
        // open reader: `ReaderWebView.performKeyEquivalent` tests its
        // zoom chord for equality with Command, deliberately so that a
        // host whose chrome keys add Shift keeps them.
        .init(binding: .literal("⇧⌘0"),
              label: "Default chrome font size",
              section: .windowAndViews, availability: .app,
              aliases: "reset the interface text size, actual size, "
                  + "put the ui text back"),
        .init(binding: .literal("⇧⌘="),
              label: "Bigger chrome font size",
              section: .windowAndViews, availability: .app,
              aliases: "make the interface bigger, larger ui text, "
                  + "zoom the app in"),
        .init(binding: .literal("⇧⌘-"),
              label: "Smaller chrome font size",
              section: .windowAndViews, availability: .app,
              aliases: "make the interface smaller, smaller ui text, "
                  + "zoom the app out"),

        .init(binding: .literal("⌘,"), label: "Settings...",
              section: .windowAndViews, availability: .app,
              aliases: "preferences, prefs, config, options"),
        // The Help-menu item carrying this key arrives with the sheet
        // itself, so this row and its command are added together — the
        // one case where the catalog is not restating something older.
        .init(binding: .literal("⌘/"), label: "Keyboard shortcuts",
              section: .windowAndViews, availability: .app,
              aliases: "cheat sheet, this sheet, hotkeys, key bindings, "
                  + "help with the keys"),
        // Physically ⇧⌘/ — one modifier from the sheet's own ⌘/ — and
        // Galaxy ships no help book (no `CFBundleHelpBookName`), so
        // `showHelp:` opens nothing. Documented because the key
        // equivalent is real and macOS shows it; the row dims for
        // nobody, which is the honest reading of a menu item that is
        // enabled and inert.
        .init(binding: .literal("⌘?"), label: "Galaxy Help",
              section: .windowAndViews, availability: .app,
              aliases: "help book, documentation, the manual"),
        .init(binding: .literal("⌃⌘F"), label: "Enter Full Screen",
              section: .windowAndViews, availability: .app,
              aliases: "fullscreen, fill the display, maximise"),
        .init(binding: .literal("⌘M"), label: "Minimize",
              section: .windowAndViews, availability: .app,
              aliases: "hide the window, send it to the dock, "
                  + "shrink the window"),
        .init(binding: .literal("⇧⌘W"), label: "Close window",
              section: .windowAndViews, availability: .app,
              aliases: "shut the window, dismiss the window, "
                  + "put galaxy away"),
        // ⌘W's fifth meaning: with nothing open, the File menu gives the
        // bare chord to the window.
        .init(binding: .literal("⌘W"), label: "Close window",
              section: .windowAndViews,
              availability: .session(.absent),
              aliases: "shut the window, dismiss the window, "
                  + "put galaxy away"),
        .init(binding: .literal("⌥⌘H"), label: "Hide Others",
              section: .windowAndViews, availability: .app,
              aliases: "focus, hide the other apps, "
                  + "get everything else out of the way"),
        .init(binding: .literal("⌘Q"), label: "Quit Galaxy",
              section: .windowAndViews, availability: .app,
              aliases: "exit, close the app, shut galaxy down"),
    ]

    // MARK: - Lists

    /// Focus moves with ⇧⌘, and ↩ opens what it lands on. The two are
    /// gated differently on purpose and the difference is visible here:
    /// ⇧⌘J still moves the focus cursor behind an open artifact reader,
    /// and ↩ no longer opens anything, because what it would open is
    /// already on screen.
    ///
    /// Five ↩ rows rather than one, because `openFocusedItemDescriptor`
    /// gives ↩ a different title on every surface, and one row reading
    /// "Open the focused item" would throw all five away. The two
    /// disabled titles get no rows: a key that is dead by construction
    /// has nothing to document.
    private static let lists: [KeystrokeEntry] = [
        .init(binding: .literal("⌘K"), label: "Previous item",
              section: .lists, availability: .listFocus,
              aliases: "move up the list, the row above, navigate up, "
                  + "focus the one above"),
        .init(binding: .literal("⌘↑"), label: "Previous item",
              section: .lists, availability: .listFocus,
              aliases: "move up the list, the row above, navigate up, "
                  + "focus the one above"),
        .init(binding: .literal("⌘J"), label: "Next item",
              section: .lists, availability: .listFocus,
              aliases: "move down the list, the row below, navigate "
                  + "down, focus the one below"),
        .init(binding: .literal("⌘↓"), label: "Next item",
              section: .lists, availability: .listFocus,
              aliases: "move down the list, the row below, navigate "
                  + "down, focus the one below"),

        // Labels are the descriptor's titles verbatim — the View menu
        // prints these, so a second wording would be a second command.
        .init(binding: .literal("↩"), label: "Open snapshot",
              section: .lists,
              availability: .viewsWithoutReader([.snapshots]),
              aliases: "read a snapshot, open the snapshot reader, "
                  + "expand the snapshot, view the snapshot"),
        .init(binding: .literal("↩"), label: "Open artifact",
              section: .lists,
              availability: .viewsWithoutReader([.artifacts]),
              aliases: "read an artifact, open the artifact reader, "
                  + "expand the artifact, view the artifact"),
        .init(binding: .literal("↩"), label: "Open agent run",
              section: .lists, availability: .views([.agents]),
              aliases: "view an agent run, expand the agent, "
                  + "agent detail, subagent detail"),
        .init(binding: .literal("↩"), label: "Reveal file in Finder",
              section: .lists,
              availability: .ledgerSubTabs([.files]),
              aliases: "show the file in Finder, find the file on disk, "
                  + "locate the file the session touched, "
                  + "open the enclosing folder"),
        .init(binding: .literal("↩"), label: "Open entry",
              section: .lists,
              availability: .ledgerSubTabs([.entries]),
              aliases: "view a ledger entry, read the entry, "
                  + "open the entry"),

        // Not a menu item: `AgentsView` installs its own escape monitor,
        // gated on the Agents tab and on a run being selected — so both
        // halves have to be stated or the row reads live in the one state
        // where the monitor is not installed at all.
        //
        // `viewsWithReader` rather than a case of its own, because the
        // question is the same one the two readers ask: is the thing this
        // tab opens over its list open right now? That the agent detail
        // is not a web view is a fact about how it draws, and no
        // keystroke here cares.
        .init(binding: .literal("esc"), label: "Close the agent run",
              section: .lists, availability: .viewsWithReader([.agents]),
              aliases: "collapse the agent, back to the agent list, "
                  + "clear the agent selection"),
    ]

    // MARK: - Reader

    /// The readers are where Galaxy's keys collide hardest. Three of
    /// these rows document keys the *menu never sees*: a reader web view
    /// in the window gets `performKeyEquivalent` before the menu bar
    /// does, and `ReaderWebView` consumes the bare-⌘ zoom trio itself
    /// while deliberately letting ⇧⌘ through — so the chrome-font rows
    /// keep working and the terminal-font rows silently do not.
    private static let reader: [KeystrokeEntry] = [
        // The File menu's title verbatim, and artifacts only — there is
        // no "Refresh snapshot", which is why this row names the
        // artifact rather than the document.
        .init(binding: .literal("⌘R"), label: "Refresh artifact",
              section: .reader,
              availability: .viewsWithReader([.artifacts]),
              aliases: "reload the artifact, re-read it from disk, "
                  + "pick up changes on disk, update the artifact"),

        .init(binding: .literal("⌘0"),
              label: "Default document zoom",
              section: .reader,
              availability: .viewsWithReader(readerViews),
              aliases: "reset the reader zoom, actual size, "
                  + "put the document text back"),
        .init(binding: .literal("⌘="), label: "Zoom the document in",
              section: .reader,
              availability: .viewsWithReader(readerViews),
              aliases: "make the document bigger, larger reader text, "
                  + "enlarge the page"),
        .init(binding: .literal("⌘-"), label: "Zoom the document out",
              section: .reader,
              availability: .viewsWithReader(readerViews),
              aliases: "make the document smaller, smaller reader text, "
                  + "shrink the page"),

        // The annotation form is configured from
        // `settings.textEntry.jsPayload` (`AnnotationSupport`), so these
        // two really do follow Settings and are named symbolically.
        .init(binding: .textEntrySubmit, label: "Save the annotation",
              section: .reader,
              availability: .viewsWithReader(readerViews),
              aliases: "submit the annotation, post the comment, "
                  + "commit the note on the document, send the overall "
                  + "comment"),
        .init(binding: .textEntryNewline,
              label: "Insert a newline in the annotation",
              section: .reader,
              availability: .viewsWithReader(readerViews),
              aliases: "line break, multiline annotation, soft return"),
        // The chord is `SendBarJS.matchesChord`, which is also what
        // draws the glyphs on the button — so the row cannot disagree
        // with the button the reader is looking at.
        //
        // Two presses, and the label says so: the first opens an overall
        // comment on the bar and the second sends. Spelling only the send
        // would describe what the second press does and leave a reader
        // wondering what the first one did.
        .init(binding: .literal("⇧⌘↩"),
              label: "Comment on the set, then send it",
              section: .reader,
              availability: .viewsWithReader(readerViews),
              aliases: "hand the annotations to the agent, submit the "
                  + "review, send the comments to claude, overall "
                  + "comment, summary comment, say what this is about"),
        // One row for a staged key. Escape unwinds a reader from the
        // outside in — the find bar first, then whatever the page has
        // open (an emoji picker, an edit in progress, an expanded note,
        // the annotation form) — and only then the reader itself. A row
        // per stage would document a decision the reader cannot see; the
        // label names the outermost act and the innermost one, which is
        // what someone pressing it needs.
        .init(binding: .literal("esc"),
              label: "Close the reader (the open form first)",
              section: .reader,
              availability: .viewsWithReader(readerViews),
              aliases: "leave the document, back to the list, dismiss "
                  + "the reader, discard the annotation form"),
    ]

    // MARK: - Terminal & agent

    /// Two panes, and the difference between them is most of this
    /// section. ⌘W closes a shell and not the agent; Escape aborts a
    /// turn in the agent's pane and is ordinary input in the shell's.
    ///
    /// ⌘S and the line-jump keys need the caret literally in a pane —
    /// their handlers test `firstResponder === pane.view`. The font keys
    /// and the buffer commands do not: they resolve a pane from the
    /// focus memory when nothing holds it, which is what keeps them
    /// working with the caret in the find bar.
    private static let terminal: [KeystrokeEntry] = [
        // Gated on a session rather than left ungated like the menu
        // items themselves. Both items are always enabled and both
        // always switch to the Terminal tab, but with no active session
        // that is *all* they do — there is no session pane to focus and
        // no shell to open beside it, so a live row would promise a
        // surface that does not exist.
        .init(binding: .literal("⌘K"), label: "Focus Session Pane",
              section: .terminal, availability: .views([.terminal]),
              aliases: "jump to the agent, go to claude, put the caret "
                  + "in the prompt, focus the session, go up a pane"),
        .init(binding: .literal("⌘J"), label: "Focus Shell Pane",
              section: .terminal, availability: .views([.terminal]),
              aliases: "go to the shell, focus the command line, "
                  + "go down a pane, switch to bash"),
        .init(binding: .literal("⌘O"), label: "Open Shell Pane",
              section: .terminal, availability: .views([.terminal]),
              aliases: "new shell, split the terminal, bash, zsh, "
                  + "open a command line"),

        // ⌘W's first meaning, and the one that wins: an app-lifetime
        // `NSEvent` monitor installed at launch consumes it before the
        // File menu is consulted at all. The monitor has a second path
        // for the find bar holding key, where it falls back to the focus
        // memory — narrower than this row says, and not worth a case of
        // its own, because the sheet is never read from inside the bar.
        .init(binding: .literal("⌘W"),
              label: "Close the focused shell pane",
              section: .terminal, availability: .pane(.shell),
              aliases: "dismiss the shell, close the split, "
                  + "quit the shell"),

        // Narrower than the menu on purpose. The item is enabled with an
        // active session on the Terminal tab, but the host that answers
        // it refuses unless the pane holds first responder — so the menu
        // is enabled and inert with the caret anywhere else, and the row
        // reports what happens rather than what the menu offers.
        .init(binding: .literal("⌘S"), label: "Scrollback",
              section: .terminal, availability: .pane(.focused),
              aliases: "history, the transcript, read back over the "
                  + "output, the buffer, what scrolled past"),

        .init(binding: .literal("⌃⌘K"), label: "Trim Buffer",
              section: .terminal, availability: .pane(.nameable),
              aliases: "prune the scrollback, drop the old output, "
                  + "tidy the buffer, shrink the history"),
        // ⌃L is the shell's own clear-screen, and this menu equivalent
        // takes it first — so in a shell pane it reflows instead of
        // clearing. Documented as what it does here, not as what the
        // key means elsewhere.
        .init(binding: .literal("⌃L"), label: "Reflow Buffer",
              section: .terminal, availability: .pane(.nameable),
              aliases: "redraw the screen, rewrap the lines, repaint "
                  + "the terminal, fix the wrapping"),

        // All three name the surface and the thing in full, so
        // "terminal", "font" and "size" each turn up the whole group
        // rather than a third of it — which is also why they do NOT
        // match the menu titles, where the three read "Default",
        // "Bigger" and "Smaller" under a heading supplying those words
        // once. A menu is never filtered; these rows are, and a lone
        // "Bigger" then says nothing about what it resizes.
        //
        // `.pane(.nameable)` already dims all three on a reader tab —
        // `targetTerminalPane()` names nothing there — so the reader's
        // zoom trio and these never read live at the same time. What
        // `.nameable` cannot express is a reader left open on a tab the
        // user is not looking at: it stays in the window and keeps
        // eating ⌘=/⌘-/⌘0, and these rows then read live on the
        // Terminal tab while the keys reach the hidden page. That is a
        // defect in the steal, not a documented behaviour, so it is
        // recorded here rather than dimmed for.
        .init(binding: .literal("⌘0"),
              label: "Default terminal font size",
              section: .terminal, availability: .pane(.nameable),
              aliases: "reset the terminal zoom, actual size, "
                  + "put the terminal text back"),
        .init(binding: .literal("⌘="),
              label: "Bigger terminal font size",
              section: .terminal, availability: .pane(.nameable),
              aliases: "zoom the terminal in, larger terminal text, "
                  + "make the terminal bigger"),
        .init(binding: .literal("⌘-"),
              label: "Smaller terminal font size",
              section: .terminal, availability: .pane(.nameable),
              aliases: "zoom the terminal out, smaller terminal text, "
                  + "make the terminal smaller"),

        // Sent as Ctrl-A / Ctrl-E, matching Terminal.app — readline and
        // the agent's input both understand those where a bare arrow
        // does not.
        .init(binding: .literal("⌃←"), label: "Jump to start of line",
              section: .terminal, availability: .pane(.focused),
              aliases: "beginning of the line, ctrl-a, home, "
                  + "back to the start of the prompt"),
        .init(binding: .literal("⌃→"), label: "Jump to end of line",
              section: .terminal, availability: .pane(.focused),
              aliases: "end of the line, ctrl-e, "
                  + "out to the end of the prompt"),

        // Galaxy does not consume this — Escape has to reach the pty,
        // because aborting the stream is the agent's own business at
        // the far end. All Galaxy does is record `turn:interrupted`,
        // and only for the session pane: a shell beside an agent has no
        // notion of a turn and is handed no `TurnInterrupt` at all.
        .init(binding: .literal("esc"),
              label: "Interrupt the agent's turn",
              section: .terminal, availability: .pane(.session),
              aliases: "stop the agent, cancel the turn, abort what "
                  + "claude is doing, halt the answer"),

        // These two are the caveat the sheet has to carry: the session
        // pane's keys come from `~/.claude/keybindings.json`, which
        // Galaxy writes from `settings.textEntry` and which anything
        // else may have written since. `ClaudeKeybindingsWriter
        // .fileState(for:)` is the only honest source for what the pane
        // actually does — the aliases carry the file's name so a reader
        // hunting it lands here.
        .init(binding: .textEntrySubmit,
              label: "Send the prompt to the agent",
              section: .terminal, availability: .pane(.session),
              aliases: "submit the prompt, commit the message, send to "
                  + "claude, claude code keybindings file"),
        .init(binding: .textEntryNewline,
              label: "Insert a newline in the prompt",
              section: .terminal, availability: .pane(.session),
              aliases: "line break, multiline prompt, soft return, "
                  + "claude code keybindings file"),
    ]

    // MARK: - Scrollback

    /// The overlay's own keys, which live in a JavaScript keydown switch
    /// and appear in no menu. assist-ant's sheet documents ⌘S and then
    /// says nothing about what ⌘S opens; this section is the difference.
    ///
    /// All of them are inert while the find bar owns the page —
    /// `handleKey` returns early on `inputSuspended` — which the Find
    /// section's rows already say, so it is not repeated per row here.
    /// The arrow and Enter rows also stand aside for a focused textarea,
    /// which is what lets the note form below have them.
    private static let scrollback: [KeystrokeEntry] = [
        .init(binding: .literal("esc"), label: "Leave the scrollback",
              section: .scrollback, availability: .scrollback,
              aliases: "close the scrollback, back to the live "
                  + "terminal, exit the history"),
        .init(binding: .literal("↑"), label: "Scroll up a line",
              section: .scrollback, availability: .scrollback,
              aliases: "move up the scrollback, one line back, "
                  + "earlier output"),
        .init(binding: .literal("↓"), label: "Scroll down a line",
              section: .scrollback, availability: .scrollback,
              aliases: "move down the scrollback, one line on, "
                  + "later output"),
        .init(binding: .literal("⇞"), label: "Page up",
              section: .scrollback, availability: .scrollback,
              aliases: "jump a screenful back, page back through the "
                  + "output"),
        .init(binding: .literal("⇟"), label: "Page down",
              section: .scrollback, availability: .scrollback,
              aliases: "jump a screenful on, page on through the "
                  + "output"),
        .init(binding: .literal("↖"),
              label: "Jump to the top of the scrollback",
              section: .scrollback, availability: .scrollback,
              aliases: "home, the oldest output, all the way back"),
        .init(binding: .literal("↘"),
              label: "Jump to the bottom of the scrollback",
              section: .scrollback, availability: .scrollback,
              aliases: "end, the newest output, all the way on, "
                  + "back to live"),
        .init(binding: .literal("↩"),
              label: "Turn the selection into a note",
              section: .scrollback, availability: .scrollback,
              aliases: "promote the selection, make a note out of what "
                  + "i selected, quote this into a note"),
        .init(binding: .textEntrySubmit, label: "Save the note",
              section: .scrollback, availability: .scrollback,
              aliases: "submit the note, commit the note, add the note, "
                  + "send the overall comment"),
        .init(binding: .textEntryNewline,
              label: "Insert a newline in the note",
              section: .scrollback, availability: .scrollback,
              aliases: "line break, multiline note, soft return"),
        // Two presses: the first opens an overall comment on the bar, the
        // second sends it ahead of the notes.
        .init(binding: .literal("⇧⌘↩"),
              label: "Comment on the notes, then send them",
              section: .scrollback, availability: .scrollback,
              aliases: "hand the notes to the agent, send them to "
                  + "claude, submit the notes, overall comment, summary "
                  + "comment, say what these are about"),
    ]

    // MARK: - Find

    /// ⌘F three times, because it has three consumers with three
    /// results. `MainMenu.canActivateFind` is the menu's visible gate
    /// and these are its three true branches, in its order; its fourth
    /// branch — Agents, Ledger, Timeline — needs no row, because
    /// `activateFind()` does nothing there.
    ///
    /// The terminal row's gate is the pane-focus memory rather than the
    /// menu's "a session exists", because that is what actually decides:
    /// `activateFindOnScrollback` answers only in the remembered pane of
    /// a visible terminal.
    private static let find: [KeystrokeEntry] = [
        .init(binding: .literal("⌘F"),
              label: "Find in the scrollback",
              section: .find, availability: .pane(.nameable),
              aliases: "search the terminal history, look through the "
                  + "transcript, grep the buffer"),
        .init(binding: .literal("⌘F"),
              label: "Find in the open artifact",
              section: .find,
              availability: .viewsWithReader([.artifacts]),
              aliases: "search the artifact, look through the document"),
        .init(binding: .literal("⌘F"),
              label: "Find in the open snapshot",
              section: .find,
              availability: .viewsWithReader([.snapshots]),
              aliases: "search the snapshot, look through the snapshot"),
        .init(binding: .literal("↩"), label: "Next match",
              section: .find, availability: .findBar,
              aliases: "find the next one, forward through the "
                  + "matches, keep going"),
        .init(binding: .literal("⇧↩"), label: "Previous match",
              section: .find, availability: .findBar,
              aliases: "find the previous one, back through the "
                  + "matches, go back one"),
        .init(binding: .literal("esc"), label: "Dismiss the find bar",
              section: .find, availability: .findBar,
              aliases: "close the search, cancel the find, "
                  + "stop searching"),
    ]

    // MARK: - Text entry

    /// The setting itself, plus the responder-chain editing keys.
    ///
    /// The two symbolic rows here are the general answer — "this is what
    /// the submit keystroke is" — and the three pairs elsewhere say what
    /// committing *means* on each surface. Both are wanted: a reader who
    /// searches "submit" is asking the first question.
    private static let textEntry: [KeystrokeEntry] = [
        .init(binding: .textEntrySubmit, label: "Send / commit text",
              section: .textEntry, availability: .app,
              aliases: "submit, post, confirm, save what i typed"),
        .init(binding: .textEntryNewline, label: "Insert a newline",
              section: .textEntry, availability: .app,
              aliases: "line break, multiline, soft return, new line"),
        .init(binding: .literal("⌘Z"), label: "Undo",
              section: .textEntry, availability: .app,
              aliases: "revert, take that back"),
        .init(binding: .literal("⇧⌘Z"), label: "Redo",
              section: .textEntry, availability: .app,
              aliases: "undo the undo, put it back"),
        .init(binding: .literal("⌘X"), label: "Cut",
              section: .textEntry, availability: .app,
              aliases: "clipboard, move the text out"),
        .init(binding: .literal("⌘C"), label: "Copy",
              section: .textEntry, availability: .app,
              aliases: "clipboard, yank, pasteboard"),
        .init(binding: .literal("⌘V"), label: "Paste",
              section: .textEntry, availability: .app,
              aliases: "clipboard, insert what i copied"),
        .init(binding: .literal("⌘A"), label: "Select All",
              section: .textEntry, availability: .app,
              aliases: "highlight all of it, mark everything"),
    ]

    // MARK: - Dialogs

    /// Galaxy's three sheets and its Settings window handle keys
    /// themselves. Documented here, but never *active* from this sheet's
    /// point of view — they are app-modal and the sheet opens from the
    /// main window — so these rows always render dimmed, which is the
    /// honest reading.
    ///
    /// Written as literal ↩ and esc, deliberately: these dialogs
    /// hardcode `.keyboardShortcut(.defaultAction)` and `.cancelAction`
    /// and so **ignore** the configured submit keystroke. Binding them
    /// symbolically would make the sheet claim they follow Settings when
    /// they do not. Fixing the dialogs is out of scope; describing them
    /// truthfully is not.
    private static let dialogs: [KeystrokeEntry] = [
        .init(binding: .literal("↩"), label: "Create the session",
              section: .dialogs,
              availability: .dialog("New Session dialog"),
              aliases: "confirm, start it, go, submit the form"),
        .init(binding: .literal("esc"), label: "Cancel",
              section: .dialogs,
              availability: .dialog("New Session dialog"),
              aliases: "close the dialog, back out, abandon it"),
        // Three `onKeyPress(.space)` handlers, one per focusable control
        // that is not a text field: the persona picker, the start
        // directory, and the Create button.
        .init(binding: .literal("␣"),
              label: "Press the focused control",
              section: .dialogs,
              availability: .dialog("New Session dialog"),
              aliases: "toggle the checkbox, pick the directory, open "
                  + "the persona list, activate the control"),

        .init(binding: .literal("↩"), label: "Create the marker",
              section: .dialogs,
              availability: .dialog("New Marker dialog"),
              aliases: "confirm, add it, submit the form"),
        .init(binding: .literal("esc"), label: "Cancel",
              section: .dialogs,
              availability: .dialog("New Marker dialog"),
              aliases: "close the dialog, back out, abandon it"),

        // Four keys for two acts, because the dialog's own monitor takes
        // both the vim pair and the arrows.
        .init(binding: .literal("⌘K"), label: "Move up the list",
              section: .dialogs,
              availability: .dialog("Restore Session dialog"),
              aliases: "the session above, navigate up, back up the "
                  + "closed sessions"),
        .init(binding: .literal("↑"), label: "Move up the list",
              section: .dialogs,
              availability: .dialog("Restore Session dialog"),
              aliases: "the session above, navigate up, back up the "
                  + "closed sessions"),
        .init(binding: .literal("⌘J"), label: "Move down the list",
              section: .dialogs,
              availability: .dialog("Restore Session dialog"),
              aliases: "the session below, navigate down, on down the "
                  + "closed sessions"),
        .init(binding: .literal("↓"), label: "Move down the list",
              section: .dialogs,
              availability: .dialog("Restore Session dialog"),
              aliases: "the session below, navigate down, on down the "
                  + "closed sessions"),
        // Bare ↩ only outside the search field — the field keeps it for
        // its own `onSubmit`, which is why the monitor checks the first
        // responder before claiming it.
        .init(binding: .literal("↩"),
              label: "Restore the selected session",
              section: .dialogs,
              availability: .dialog("Restore Session dialog"),
              aliases: "reopen it, bring it back, confirm the restore"),
        .init(binding: .literal("esc"), label: "Cancel",
              section: .dialogs,
              availability: .dialog("Restore Session dialog"),
              aliases: "close the dialog, back out, abandon it"),

        .init(binding: .literal("esc"), label: "Close Settings",
              section: .dialogs,
              availability: .dialog("Settings window"),
              aliases: "dismiss preferences, leave the settings, "
                  + "back out of prefs"),
    ]
}
