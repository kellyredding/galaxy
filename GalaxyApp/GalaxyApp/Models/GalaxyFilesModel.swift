import AppKit
import Combine
import Foundation
import Galactic

/// Galaxy's answers about its Files surface, and nothing else.
///
/// **The surface itself is Galactic's** — see `FilesSurface`. What is here is
/// the five things `FilesHost` asks, plus the one thing this app has that the
/// other does not: a navigation history that needs to know which file is
/// selected.
///
/// **Many owners, keyed by session id.** That is the whole structural difference
/// between this host and Assist Ant, which names a single owner as a constant.
/// Both go through `FilesSurface`, so the difference stays this string.
@MainActor
final class GalaxyFilesModel: FilesHost {
    static let shared = GalaxyFilesModel()

    private(set) var surface: FilesSurface!

    // The three keystrokes the Files pane answers, as publishers because that is
    // what the shared view observes. Held here rather than on `MenuActions` so
    // the menu has one object to talk to about Files.
    let findActivations = PassthroughSubject<Void, Never>()
    let lineJumpActivations = PassthroughSubject<Void, Never>()
    let searchActivations = PassthroughSubject<Void, Never>()

    func activateFind() { findActivations.send() }
    func activateLineJump() { lineJumpActivations.send() }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        surface = FilesSurface(
            host: self, store: FilesStatePersistence.shared
        )
        surface.connectPresenters()
        // Galaxy's alone: the strip's selection has to reach `Session` so the
        // navigation coordinator can record it and write it back on
        // back/forward. Assist Ant has no history to feed, which is why this is
        // a hook rather than a protocol member.
        surface.onSelectionChanged = { [weak self] path in
            self?.mirrorSelection(path)
        }
        observeFilesTabEntry()
    }

    // MARK: - Following the agent

    /// Ask on arrival at Files, never on the agent's event.
    ///
    /// A reader working in the Files tab while the agent moves around keeps the
    /// tree they are working in; the question is put again the next time they
    /// come back to the surface.
    ///
    /// **`removeDuplicates` is what makes this a transition rather than an
    /// assignment.** `showFilesSurface()` sets `activeTab` to `.files` whether
    /// or not it is already there, so opening the picker from inside the Files
    /// tab would otherwise re-root under a reader who never went anywhere.
    private func observeFilesTabEntry() {
        SessionManager.shared.$activeTab
            .removeDuplicates()
            .sink { [weak self] tab in
                guard tab == .files,
                    !SessionManager.shared.isRestoringTab
                else { return }
                self?.followAgentRootIfMoved()
            }
            .store(in: &cancellables)
    }

    /// Re-root the visible set to the agent's directory, if it has moved.
    ///
    /// `ledgerCwd` directly rather than `ShellLauncher.resolveCwd`, and that is
    /// the difference between following an agent and guessing. `resolveCwd`
    /// falls back through the project directory to the home directory so a
    /// shell always has somewhere to open; here a missing directory means the
    /// agent is not somewhere we can follow, and the honest answer is to leave
    /// the reader's root alone rather than re-root them to `$HOME`.
    private func followAgentRootIfMoved() {
        guard let session = SessionManager.shared.activeSession,
            let cwd = session.ledgerCwd, !cwd.isEmpty,
            FileManager.default.fileExists(atPath: cwd)
        else { return }
        surface.followAgentRoot(to: URL(fileURLWithPath: cwd))
    }

    // MARK: - FilesHost

    var currentOwnerID: String {
        SessionManager.shared.activeSessionId?.uuidString ?? ""
    }

    func defaultRoot(forOwner ownerID: String) -> URL {
        // `resolveCwd` rather than `Session.workingDirectory`, which is where
        // the session was *created*. This follows the same chain the shell pane
        // opens in — where Claude most recently `cd`'d, then the project dir,
        // then the creation directory — skipping any that is no longer on disk.
        // A reader opening Files expects the tree the agent is working in.
        let session = SessionManager.shared.session(forOwnerID: ownerID)
        return URL(fileURLWithPath: ShellLauncher.resolveCwd(for: session))
    }

    func showFilesSurface() {
        SessionManager.shared.activeTab = .files
    }

    func showAgentSurface() {
        SessionManager.shared.activeTab = .terminal
    }

    /// Queued on the owning session's inbox rather than the active one's.
    ///
    /// They are the same session in every path that reaches here today, but the
    /// review was composed against a particular set and belongs to that set's
    /// agent — resolving it from the owner rather than from what is in front
    /// means a switch mid-send cannot deliver it to the wrong conversation.
    func deliverReview(_ review: String, forOwner ownerID: String) {
        guard let session = SessionManager.shared.session(forOwnerID: ownerID)
        else { return }
        session.enqueueMessage(review, sourceLabel: "File review")
    }

    var textEntryPayload: [String: [[String: Any]]]? {
        SettingsManager.shared.settings.textEntry.jsPayload
    }

    var searchContextLines: Int {
        SettingsManager.shared.settings.fileSearchContextLines
    }

    // MARK: - Per-session sets

    func set(for session: Session) -> FileSet {
        surface.set(forOwner: session.id.uuidString)
    }

    func restoreIfNeeded(for session: Session) {
        surface.restoreIfNeeded(ownerID: session.id.uuidString)
    }

    func discard(session: Session) {
        surface.discard(ownerID: session.id.uuidString)
    }

    var pendingNoteTally: (notes: Int, files: Int) { surface.pendingNoteTally }

    // MARK: - History

    /// Copy the strip's selection onto the session that owns it.
    ///
    /// Resolved from the current owner rather than from the active session, so a
    /// change that lands while a switch is in flight is still filed against the
    /// set it came from.
    private func mirrorSelection(_ path: String?) {
        guard
            let session = SessionManager.shared.session(
                forOwnerID: currentOwnerID
            )
        else { return }
        if let path { session.recordFileInfo(path: path) }
        guard session.selectedFilePath != path else { return }
        session.selectedFilePath = path
    }

    /// Put the strip where the coordinator says it should be — the other
    /// direction of the mirror, for back and forward.
    ///
    /// A path that is not open is opened, because a history entry naming a file
    /// the reader has since closed should still take them to it.
    func applySelection(_ path: String?, to session: Session) {
        guard let path else { return }
        let set = set(for: session)
        guard set.selectedPath != path else { return }
        if let existing = set.tabs.tab(forPath: path) {
            set.select(id: existing.id)
        } else {
            try? set.open(url: URL(fileURLWithPath: path))
        }
    }

    // MARK: - What the menu asks
    //
    // Forwarded so the menu has one name to call rather than reaching past this
    // object into the package.

    /// Reach a path from somewhere else in the app — the Ledger's file list is
    /// the first caller. Shows the Files surface and selects the file if it is
    /// already open.
    func selectOrOpen(path: String) { surface.selectOrOpen(path: path) }

    func revealSelectedFile() { surface.revealSelectedFile() }

    func presentPicker() { surface.presentPicker() }
    func presentSearcher() { surface.presentSearcher() }
    func dismissPanelsIfPresented() { surface.dismissPanels() }
    func closeSelected() { surface.closeSelected() }
    func reopenLastClosed() { surface.reopenLastClosed() }
    func selectPreviousFile() { surface.selectPreviousFile() }
    func selectNextFile() { surface.selectNextFile() }
    func selectPreviousInnerTab() { surface.selectPreviousInnerTab() }
    func selectNextInnerTab() { surface.selectNextInnerTab() }
    func selectPreviousRow() { surface.selectPreviousRow() }
    func selectNextRow() { surface.selectNextRow() }

    var hasClosedFiles: Bool { surface.hasClosedFiles }
    var hasMultipleRows: Bool { surface.hasMultipleRows }
    var canSelectPreviousFile: Bool { surface.canSelectPreviousFile }
    var canSelectNextFile: Bool { surface.canSelectNextFile }
    var hasFileOpen: Bool { surface.hasFileOpen }
}
