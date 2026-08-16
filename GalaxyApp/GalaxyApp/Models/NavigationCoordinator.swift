import Foundation
import Combine

/// Per-session coordinator that records navigation changes to
/// history and applies routes for back/forward restoration.
///
/// Lifetime: one per Session, owned by the Session. Alive the
/// whole time the Session object exists.
///
/// Recording path:
///   Any @Published state change → debounced 50ms → derive
///   currentRoute → push to history if changed AND not
///   suppressing.
///
/// Restoration path:
///   apply(route:) sets isSuppressingRecording=true, mutates
///   state directly, clears flag after debounce window.
final class NavigationCoordinator {
    private unowned let session: Session
    private unowned let sessionManager: SessionManager
    let history: SessionNavigationHistory

    /// When true, route changes are observed but NOT recorded.
    /// Set during back/forward restoration and session-switch
    /// state shuffles.
    private(set) var isSuppressingRecording: Bool = false

    /// Last route we pushed — used for dedup and to skip
    /// intermediate emissions during batched mutations.
    private var lastRecordedRoute: NavigationRoute?

    private var cancellables: Set<AnyCancellable> = []
    private static let debounceMs: Int = 50
    private static let suppressionReleaseMs: Int = 100

    init(session: Session, sessionManager: SessionManager) {
        self.session = session
        self.sessionManager = sessionManager
        self.history = SessionNavigationHistory()
        subscribe()
    }

    // MARK: - Recording

    private func subscribe() {
        // Merge all signals that contribute to the current
        // route into one stream. debounce collapses batched
        // mutations (e.g., tab + number set in the same tick)
        // into a single recorded entry.
        let tabSignal: AnyPublisher<Void, Never> =
            sessionManager.$activeTab
            .map { _ in () }
            .eraseToAnyPublisher()
        let subTabSignal: AnyPublisher<Void, Never> =
            sessionManager.$activeLedgerSubTab
            .map { _ in () }
            .eraseToAnyPublisher()
        let artifactSignal: AnyPublisher<Void, Never> =
            session.$openArtifactNumber
            .map { _ in () }
            .eraseToAnyPublisher()
        let snapshotSignal: AnyPublisher<Void, Never> =
            session.$openSnapshotNumber
            .map { _ in () }
            .eraseToAnyPublisher()
        let agentSignal: AnyPublisher<Void, Never> =
            session.$selectedAgentId
            .map { _ in () }
            .eraseToAnyPublisher()

        let signals: [AnyPublisher<Void, Never>] = [
            tabSignal, subTabSignal,
            artifactSignal, snapshotSignal, agentSignal,
        ]

        Publishers.MergeMany(signals)
            .debounce(
                for: .milliseconds(Self.debounceMs),
                scheduler: DispatchQueue.main
            )
            .sink { [weak self] _ in
                self?.recordCurrentRouteIfChanged()
            }
            .store(in: &cancellables)
    }

    /// Compute current route from observed state and push to
    /// history unless suppressing or unchanged.
    private func recordCurrentRouteIfChanged() {
        guard !isSuppressingRecording else { return }

        // Only record for the active session. Inactive sessions
        // still emit signals when state changes (e.g., an
        // external event), but those should not interleave into
        // the active session's history.
        guard session.id == sessionManager.activeSessionId
        else { return }

        let route = deriveCurrentRoute()
        if route == lastRecordedRoute { return }

        let entry = NavigationEntry(
            route: route,
            displayTitle: Self.titleFor(
                route: route, session: session
            )
        )
        history.push(entry)
        lastRecordedRoute = route
    }

    private func deriveCurrentRoute() -> NavigationRoute {
        switch sessionManager.activeTab {
        case .terminal:
            return .terminal()
        case .timeline:
            return .timeline()
        case .ledger:
            return .ledger(sessionManager.activeLedgerSubTab)
        case .artifacts:
            return .artifacts(
                number: session.openArtifactNumber
            )
        case .snapshots:
            return .snapshots(
                number: session.openSnapshotNumber
            )
        case .agents:
            return .agents(id: session.selectedAgentId)
        }
    }

    // MARK: - Restoration

    /// Navigate one step back in history and apply the
    /// resulting route. No-op if no previous entry.
    func navigateBack() {
        guard let route = history.back() else { return }
        apply(route: route)
    }

    /// Navigate one step forward in history and apply.
    func navigateForward() {
        guard let route = history.forward() else { return }
        apply(route: route)
    }

    /// Jump to a specific entry (from dropdown selection).
    func jumpTo(entryId: UUID) {
        guard let route = history.jump(to: entryId)
        else { return }
        apply(route: route)
    }

    /// Mutate hoisted state to match the route. Suppresses
    /// recording for the debounce window so the resulting
    /// @Published emissions don't create a new history entry.
    private func apply(route: NavigationRoute) {
        isSuppressingRecording = true

        // Apply identifiers FIRST so the tab switch lands on a
        // view that's already showing the right item (avoids a
        // flash of the index before the reader opens).
        session.openArtifactNumber = route.artifactNumber
        session.openSnapshotNumber = route.snapshotNumber
        session.selectedAgentId = route.agentId

        // Exhaustive rather than an `if` naming the one view that carries a
        // sub-selection, because this is the one place a new view can be
        // added and *compile*. `deriveCurrentRoute` and `titleFor` both fail
        // the build without it; forgetting it here means back and forward
        // reach the right tab and leave whatever was already open on screen,
        // which reads as history losing its place rather than as a missing
        // case.
        switch route.tab {
        case .ledger:
            if let sub = route.ledgerSubTab {
                sessionManager.activeLedgerSubTab = sub
            }
        case .terminal, .timeline, .agents, .artifacts, .snapshots:
            break
        }
        sessionManager.activeTab = route.tab

        // Update lastRecordedRoute so the next user-initiated
        // change compares against the restored position, not
        // the pre-restoration state.
        lastRecordedRoute = route

        // Release the suppression flag after the debounce
        // window so @Published emissions from the mutations
        // above have drained without triggering a record.
        let delay = DispatchTimeInterval.milliseconds(
            Self.suppressionReleaseMs
        )
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay
        ) { [weak self] in
            self?.isSuppressingRecording = false
        }
    }

    /// Called by SessionManager.switchTo. Blocks the
    /// session-switch state shuffle (saveViewState →
    /// restoreViewState → drainPendingShows) from polluting
    /// history.
    func suppressForSessionSwitch() {
        isSuppressingRecording = true
        let delay = DispatchTimeInterval.milliseconds(
            Self.suppressionReleaseMs
        )
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay
        ) { [weak self] in
            self?.isSuppressingRecording = false
        }
    }

    // MARK: - Title derivation

    /// Produces the human-readable title shown in dropdowns.
    /// Captured at push time — the view layer seeds the
    /// session's caches as it loads data.
    private static func titleFor(
        route: NavigationRoute,
        session: Session
    ) -> String {
        switch route.tab {
        case .terminal:
            return "Terminal"
        case .timeline:
            return "Timeline"
        case .ledger:
            let sub = route.ledgerSubTab?.rawValue ?? ""
            return "Ledger — \(sub)"
        case .artifacts:
            guard let number = route.artifactNumber else {
                return "Artifacts"
            }
            return session.artifactTitle(for: number)
                ?? "Artifact #\(number)"
        case .snapshots:
            guard let number = route.snapshotNumber else {
                return "Snapshots"
            }
            return session.snapshotTitle(for: number)
                ?? "Snapshot #\(number)"
        case .agents:
            guard let id = route.agentId else {
                return "Agents"
            }
            return session.agentTitle(for: id)
                ?? "Agent \(id.prefix(8))"
        }
    }
}
