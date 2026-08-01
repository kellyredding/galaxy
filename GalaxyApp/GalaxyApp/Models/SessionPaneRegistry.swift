import Combine
import Foundation
import Galactic

/// One session's terminal panes, addressable as a unit.
///
/// Held per session rather than app-wide, which is the whole reason this is a
/// type of its own: the quit sheet names *sessions* holding unsaved work, and a
/// single app-wide answer cannot say which session a note belongs to. A
/// consumer is handed the registry belonging to the session it is serving, and
/// resolves it through the pane the same way the session itself is resolved.
///
/// Lived on the session model until it grew into two registries and a
/// cross-pane flag with their own lifecycle, none of which is what a session
/// *is*. The session still owns one, so the ownership is unchanged; what moved
/// is the machinery.
///
/// Deliberately not an `ObservableObject`. The one piece of state anything
/// observes exposes a publisher explicitly, and conforming would put every
/// write back on the path that invalidates every view holding the session —
/// which is what this being on the session model used to do for writes nothing
/// was listening to.
final class SessionPaneRegistry: TerminalPaneRegistry {

    // MARK: - Focus memory

    /// Which pane was most recently the first responder, so tab-switch,
    /// session-switch and window-becomes-key restoration land the user back on
    /// whichever pane they were last typing in.
    ///
    /// Plain rather than published: nothing routes on changes to it — every
    /// consumer reads it at the moment it has a decision to make. It was
    /// published on the session model, where each write invalidated every view
    /// holding that session, for no subscriber at all.
    var lastFocusedPaneKind: TerminalPaneKind = .session

    /// Per-host restoration closures, keyed by the registering host's identity
    /// and tagged with the kind of pane each restores.
    private var focusRestorers: [
        ObjectIdentifier: (kind: TerminalPaneKind, restore: () -> Void)
    ] = [:]

    func registerFocusRestorer(
        _ key: ObjectIdentifier,
        kind: TerminalPaneKind,
        restore: @escaping () -> Void
    ) {
        focusRestorers[key] = (kind: kind, restore: restore)
    }

    func unregisterFocusRestorer(_ key: ObjectIdentifier) {
        focusRestorers.removeValue(forKey: key)
    }

    /// Restore focus to the pane matching `lastFocusedPaneKind`, falling back
    /// when that pane is not registered — the user may remember being in a
    /// shell that has since closed.
    ///
    /// Every tier names its kind, so which pane wins never depends on the
    /// order the storage happens to yield.
    func restorePreferredPaneFocus() {
        if restoreIfRegistered(kind: lastFocusedPaneKind) { return }
        // The session pane wins the fallback: it is the one that always exists.
        if restoreIfRegistered(kind: .session) { return }
        _ = restoreIfRegistered(kind: .shell)
    }

    /// Restore focus to the pane of exactly `kind`, ignoring the focus memory.
    ///
    /// Restoring through the host rather than the pane is the point: a host
    /// routes focus into an open scrollback overlay, where focusing the pane
    /// directly would land on the live terminal hidden beneath it and leave
    /// the overlay visible but keyboard-dead.
    func restoreFocus(kind: TerminalPaneKind) {
        _ = restoreIfRegistered(kind: kind)
    }

    /// Invoke the restorer for `kind`, reporting whether there was one.
    private func restoreIfRegistered(kind: TerminalPaneKind) -> Bool {
        guard
            let entry = focusRestorers.values.first(where: { $0.kind == kind })
        else { return false }
        entry.restore()
        return true
    }

    // MARK: - Cross-pane scrollback state

    /// True while the session pane's scrollback overlay is open.
    ///
    /// The shell pane's Send to Claude reads it: sending into the agent while
    /// its buffer is frozen open would land text the user cannot see arriving.
    /// Held here rather than on either pane so neither has to know the other
    /// exists, and so it survives a pane being torn down and rebuilt.
    @Published private(set) var sessionPaneScrollbackActive = false

    var sessionPaneScrollbackActivePublisher: AnyPublisher<Bool, Never> {
        $sessionPaneScrollbackActive.eraseToAnyPublisher()
    }

    func setSessionPaneScrollbackActive(_ active: Bool) {
        guard sessionPaneScrollbackActive != active else { return }
        sessionPaneScrollbackActive = active
    }

    // MARK: - Unsaved work

    /// Per-host checks for unsaved scrollback work — committed notes not yet
    /// sent, an open note form with text, an edit in progress.
    ///
    /// Asynchronous because the answer lives in the scrollback overlay's web
    /// view and has to be fetched from JavaScript.
    private var unsavedWorkCheckers: [
        ObjectIdentifier: (
            kind: TerminalPaneKind,
            check: (@escaping (Bool) -> Void) -> Void
        )
    ] = [:]

    func registerUnsavedWorkChecker(
        _ key: ObjectIdentifier,
        kind: TerminalPaneKind,
        checker: @escaping (@escaping (Bool) -> Void) -> Void
    ) {
        unsavedWorkCheckers[key] = (kind: kind, check: checker)
    }

    func unregisterUnsavedWorkChecker(_ key: ObjectIdentifier) {
        unsavedWorkCheckers.removeValue(forKey: key)
    }

    /// Ask the panes matching `kinds` whether they hold unsaved work and
    /// report the subset that does, so a caller can name them. Checks run
    /// concurrently; the completion lands on main.
    ///
    /// Which kinds are worth asking about is the caller's to say: stopping a
    /// session only loses the session pane's notes because the shell process
    /// keeps running, while quitting loses both — and for an already-stopped
    /// session, only its shell pane can still be open.
    func checkUnsavedWork(
        kinds: Set<TerminalPaneKind>,
        completion: @escaping (Set<TerminalPaneKind>) -> Void
    ) {
        let entries = unsavedWorkCheckers.values
            .filter { kinds.contains($0.kind) }

        guard !entries.isEmpty else {
            // Deliberately asynchronous even though the answer is already
            // known. Quit answers AppKit that it will terminate later and then
            // replies from a completion below this one; answering inline would
            // reply before that return, out of the order AppKit documents.
            // Every other path out of here lands on `group.notify`, and one
            // method with two reentrancy semantics — chosen by whether a pane
            // happens to be registered — is the harder bug to find.
            DispatchQueue.main.async { completion([]) }
            return
        }

        let group = DispatchGroup()
        var panesWithWork: Set<TerminalPaneKind> = []
        let lock = NSLock()

        for entry in entries {
            group.enter()
            entry.check { hasWork in
                if hasWork {
                    lock.lock()
                    panesWithWork.insert(entry.kind)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(panesWithWork)
        }
    }
}
