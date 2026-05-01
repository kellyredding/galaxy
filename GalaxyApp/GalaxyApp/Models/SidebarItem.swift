import Foundation

/// One row in the sidebar's ordered list. Sessions and markers
/// share a single index space — drag-to-reorder operates here,
/// not on Session or SessionMarker individually.
///
/// `SessionManager.sidebarItems` is the source of truth for sidebar
/// order; `SessionManager.sessions` is a computed filter over this
/// list, preserving the existing read-only API surface.
enum SidebarItem: Identifiable {
    case session(Session)
    case marker(SessionMarker)

    var id: UUID {
        switch self {
        case .session(let s): return s.id
        case .marker(let m): return m.id
        }
    }

    var session: Session? {
        if case .session(let s) = self { return s }
        return nil
    }

    var marker: SessionMarker? {
        if case .marker(let m) = self { return m }
        return nil
    }
}
