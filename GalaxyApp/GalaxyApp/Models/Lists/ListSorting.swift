import Foundation

/// Comparison helpers for the sortable list views.
///
/// Foundation only, so the smoke tool can link it without the app.
///
/// The point of the file is that a comparator answers with a
/// `ComparisonResult` rather than a `Bool`. A `Bool` cannot say "equal", so
/// flipping one to get a descending sort claims both that a comes before b
/// and that b comes before a for every pair sharing a key — which on these
/// columns is most pairs, since importance holds three values, ops about
/// fifteen, and an agent type or status repeats across a whole session.
/// Sorting with that predicate has no defined result.
enum ListSorting {
    /// Three-way comparison over any `Comparable`.
    static func compare<T: Comparable>(
        _ a: T, _ b: T
    ) -> ComparisonResult {
        if a < b { return .orderedAscending }
        if b < a { return .orderedDescending }
        return .orderedSame
    }

    /// Three-way comparison for text a reader reads, which is every string
    /// column in these lists that is not a timestamp.
    ///
    /// Timestamps stay on `compare`: they arrive as fixed-width UTC strings
    /// whose byte order already is their chronological order, and collating
    /// them as prose would only invite a locale to disagree.
    static func compareText(
        _ a: String, _ b: String
    ) -> ComparisonResult {
        a.localizedCaseInsensitiveCompare(b)
    }

    /// Rank for a ledger entry's importance.
    ///
    /// Stored as text, and its useful order is not its alphabetical one:
    /// sorted as prose, "low" lands between "high" and "medium".
    static func importanceRank(_ importance: String) -> Int {
        switch importance.lowercased() {
        case "high": return 0
        case "medium": return 1
        case "low": return 2
        default: return 3
        }
    }

    /// Apply a direction to a three-way result.
    ///
    /// Equal keys answer false whichever way the column points, which is
    /// what keeps the ordering a valid one.
    static func ordered(
        _ result: ComparisonResult, ascending: Bool
    ) -> Bool {
        ascending
            ? result == .orderedAscending
            : result == .orderedDescending
    }
}
