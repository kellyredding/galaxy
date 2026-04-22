import Foundation
import Combine

/// Per-session, in-memory browser-style navigation history.
///
/// Semantics match browser history:
/// - `push` truncates the forward stack and appends at the end
/// - Consecutive duplicates (same route as current) are deduped
/// - `back` / `forward` move the cursor without mutating the
///   stack
///
/// No cap on stored entries — each entry is tiny (<300 bytes)
/// and history dies on Galaxy restart. Dropdowns cap displayed
/// entries at `dropdownCap` via `backEntries` / `forwardEntries`.
final class SessionNavigationHistory: ObservableObject {
    @Published private(set) var entries: [NavigationEntry] = []
    @Published private(set) var currentIndex: Int = -1

    private static let dropdownCap = 15

    var canGoBack: Bool { currentIndex > 0 }

    var canGoForward: Bool {
        currentIndex >= 0 && currentIndex < entries.count - 1
    }

    var currentEntry: NavigationEntry? {
        guard entries.indices.contains(currentIndex) else {
            return nil
        }
        return entries[currentIndex]
    }

    /// Entries visible in the back-button long-press dropdown.
    /// Most-recent-first (top of list = one step back). Capped.
    var backEntries: [NavigationEntry] {
        guard canGoBack else { return [] }
        let slice = entries[0..<currentIndex].reversed()
        return Array(slice.prefix(Self.dropdownCap))
    }

    /// Entries visible in the forward-button long-press dropdown.
    /// Oldest-first (top of list = one step forward). Capped.
    var forwardEntries: [NavigationEntry] {
        guard canGoForward else { return [] }
        let slice = entries[(currentIndex + 1)...]
        return Array(slice.prefix(Self.dropdownCap))
    }

    /// Push a new entry. Truncates any forward stack. No-op if
    /// the new route equals the current route (dedup).
    func push(_ entry: NavigationEntry) {
        if let current = currentEntry,
           current.route == entry.route
        {
            return
        }
        if canGoForward {
            entries.removeSubrange((currentIndex + 1)...)
        }
        entries.append(entry)
        currentIndex = entries.count - 1
    }

    /// Move cursor back one step. Returns the target route, or
    /// nil if no previous entry. Does not mutate the stack.
    @discardableResult
    func back() -> NavigationRoute? {
        guard canGoBack else { return nil }
        currentIndex -= 1
        return entries[currentIndex].route
    }

    /// Move cursor forward one step. Returns the target route,
    /// or nil if no next entry. Does not mutate the stack.
    @discardableResult
    func forward() -> NavigationRoute? {
        guard canGoForward else { return nil }
        currentIndex += 1
        return entries[currentIndex].route
    }

    /// Jump directly to a specific entry by id (from dropdown
    /// selection). Returns the target route, or nil if not
    /// found.
    @discardableResult
    func jump(to entryId: UUID) -> NavigationRoute? {
        guard let idx = entries.firstIndex(
            where: { $0.id == entryId }
        ) else { return nil }
        currentIndex = idx
        return entries[idx].route
    }
}
