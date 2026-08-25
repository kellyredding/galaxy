import Foundation

/// Identifies a navigable location within a session.
///
/// Value type — full equality comparison is used for dedup and
/// "current route" checks. Pattern: exactly one tab + at most
/// one extra identifier appropriate to that tab.
///
/// Constructors enforce the validity pairing (e.g., only
/// `.ledger` routes carry a subtab, only `.artifacts` routes
/// carry a number). Construct via static factories — the
/// memberwise init is private to prevent ill-formed routes.
struct NavigationRoute: Equatable, Hashable {
    let tab: SessionTab
    let ledgerSubTab: LedgerSubTab?
    let artifactNumber: Int32?
    let snapshotNumber: Int32?
    let agentId: String?
    /// Absolute path of the file selected in the Files strip.
    let filePath: String?

    private init(
        tab: SessionTab,
        ledgerSubTab: LedgerSubTab? = nil,
        artifactNumber: Int32? = nil,
        snapshotNumber: Int32? = nil,
        agentId: String? = nil,
        filePath: String? = nil
    ) {
        self.tab = tab
        self.ledgerSubTab = ledgerSubTab
        self.artifactNumber = artifactNumber
        self.snapshotNumber = snapshotNumber
        self.agentId = agentId
        self.filePath = filePath
    }

    static func terminal() -> Self {
        .init(tab: .terminal)
    }

    static func timeline() -> Self {
        .init(tab: .timeline)
    }

    static func ledger(_ subTab: LedgerSubTab) -> Self {
        .init(tab: .ledger, ledgerSubTab: subTab)
    }

    static func artifacts(number: Int32? = nil) -> Self {
        .init(tab: .artifacts, artifactNumber: number)
    }

    static func snapshots(number: Int32? = nil) -> Self {
        .init(tab: .snapshots, snapshotNumber: number)
    }

    static func agents(id: String? = nil) -> Self {
        .init(tab: .agents, agentId: id)
    }

    static func files(path: String? = nil) -> Self {
        .init(tab: .files, filePath: path)
    }
}
