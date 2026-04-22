import Foundation

/// One recorded navigation history entry.
///
/// Display title is captured at push time so dropdowns remain
/// stable even if the underlying artifact/snapshot/agent is
/// later deleted or renamed.
struct NavigationEntry: Identifiable, Equatable {
    let id: UUID
    let route: NavigationRoute
    let displayTitle: String
    let timestamp: Date

    init(
        route: NavigationRoute,
        displayTitle: String,
        timestamp: Date = Date()
    ) {
        self.id = UUID()
        self.route = route
        self.displayTitle = displayTitle
        self.timestamp = timestamp
    }
}
