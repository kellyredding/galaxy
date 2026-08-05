import Foundation

// Sandboxed smoke check for the sortable lists' model. Runs as its own
// process — no app, no window, no SessionManager. Run via `make smoke`.
// Exits non-zero if any check fails.
//
// It exists because the five list views had no coverage of any kind. Their
// ordering, their selection bookkeeping and their timestamp policy all lived
// inside `View` structs, where no target but the app could reach them, and
// they had drifted into the same defects five times over without anything
// objecting.
//
// What is asserted here is what a reader of those views cannot check by
// reading: that a descending sort is still a valid ordering when keys repeat,
// that importance ranks by meaning rather than by alphabet, and that a
// timestamp is parsed as the machine format it is rather than through whatever
// calendar the system happens to be set to.
//
// What this does NOT check, stated plainly: anything with a pixel in it.
// Column widths, row construction and header placement stay per-view and are
// only verifiable by looking at five tabs at several window widths.

var failures = 0

func check(_ name: String, _ body: () throws -> Bool) {
    do {
        if try body() {
            print("PASS  \(name)")
        } else {
            print("FAIL  \(name)")
            failures += 1
        }
    } catch {
        print("FAIL  \(name) — threw: \(error)")
        failures += 1
    }
}

// MARK: - Fixtures

/// A Gregorian UTC calendar, built rather than borrowed from the environment
/// so a check means the same thing on any machine.
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!

/// An instant, from its UTC wall-clock parts. Deliberately not built by
/// calling the parser under test.
func at(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
) -> Date {
    utc.date(
        from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second))!
}

// MARK: - Ordering

// The defect this file exists to prevent. Five comparators built a Bool and
// negated it, and a Bool has no way to say "equal" — so descending answered
// true for both (a, b) and (b, a), claiming each row precedes the other.
check("sorting: equal keys are not ordered, whichever way the column points") {
    let order = ListSorting.compare(5, 5)
    return order == .orderedSame
        && !ListSorting.ordered(order, ascending: true)
        && !ListSorting.ordered(order, ascending: false)
}

check("sorting: distinct keys reverse when the direction does") {
    let ab = ListSorting.compare(1, 2)
    let ba = ListSorting.compare(2, 1)
    return ListSorting.ordered(ab, ascending: true)
        && !ListSorting.ordered(ba, ascending: true)
        && !ListSorting.ordered(ab, ascending: false)
        && ListSorting.ordered(ba, ascending: false)
}

check("sorting: text compares as a reader reads it, not by code point") {
    // "apple" before "Banana" — a byte comparison puts every capital first.
    ListSorting.compareText("apple", "Banana") == .orderedAscending
        && ListSorting.compareText("Apple", "apple") == .orderedSame
}

check("sorting: importance ranks high, medium, low") {
    let ranked = ["low", "high", "unknown", "medium"]
        .sorted {
            ListSorting.importanceRank($0)
                < ListSorting.importanceRank($1)
        }
    return ranked == ["high", "medium", "low", "unknown"]
}

// The ledger entries list opens on this column, so the alphabet's answer —
// high, low, medium — was the first thing anyone saw on that tab.
check("sorting: importance does not order like the alphabet") {
    let byRank = ListSorting.compare(
        ListSorting.importanceRank("low"),
        ListSorting.importanceRank("medium"))
    let byText = ListSorting.compareText("low", "medium")
    return byRank == .orderedDescending && byText == .orderedAscending
}

// MARK: - Timestamps

check("timestamp: SQLite datetime is read as UTC") {
    ListTimestamp.parse("2025-03-30 16:03:12")
        == at(2025, 3, 30, 16, 3, 12)
}

check("timestamp: RFC3339 is read too, for the ledger's last attempt") {
    ListTimestamp.parse("2025-03-30T16:03:12Z")
        == at(2025, 3, 30, 16, 3, 12)
}

// The failure this pins down: the parser it replaced set no locale, so under
// a non-Gregorian system calendar it read 2025 as a Buddhist year and the
// caller printed the raw string. Fixing the locale is only meaningful if a
// locale could have broken it, so both halves are asserted.
check("timestamp: parsing ignores the system calendar") {
    let naive = DateFormatter()
    naive.dateFormat = "yyyy-MM-dd HH:mm:ss"
    naive.timeZone = TimeZone(identifier: "UTC")
    naive.locale = Locale(identifier: "th_TH_TRADITIONAL")
    let ours = ListTimestamp.parse("2025-03-30 16:03:12")
    return ours == at(2025, 3, 30, 16, 3, 12)
        && naive.date(from: "2025-03-30 16:03:12") != ours
}

check("timestamp: an unparseable value comes back unchanged") {
    ListTimestamp.format(
        "not a date", now: at(2025, 3, 30), calendar: utc) == "not a date"
}

check("timestamp: the four tiers select by distance from now") {
    let now = at(2025, 3, 30, 16, 3, 12)
    let cases: [(Date, ListTimestamp.Tier)] = [
        (at(2025, 3, 30, 9), .today),
        (at(2025, 3, 27, 9), .thisWeek),
        (at(2025, 1, 5, 9), .thisYear),
        (at(2024, 12, 31, 9), .older),
    ]
    return cases.allSatisfy {
        ListTimestamp.tier(for: $0.0, now: now, calendar: utc) == $0.1
    }
}

check("timestamp: a tier prints only what it needs to") {
    let now = at(2025, 3, 30, 16, 3, 12)
    let today = ListTimestamp.format(
        "2025-03-30 09:00:00", now: now, calendar: utc)
    let older = ListTimestamp.format(
        "2024-12-31 09:00:00", now: now, calendar: utc)
    // Today spends no width on a date; an older row spells out the year.
    return !today.contains("2025") && older.contains("2024")
}

// MARK: - Order and selection

private struct Row: Identifiable {
    let id: Int
    let name: String
    let count: Int
}

private let rowColumns: [ListColumn<Row, String>] = [
    .init("name", title: "Name") {
        ListSorting.compareText($0.name, $1.name)
    },
    .init("count", title: "Count", prefersAscending: false) {
        ListSorting.compare($0.count, $1.count)
    },
]

private func rowModel(
    sortColumn: String = "name", ascending: Bool = true
) -> ListSortModel<Row, String> {
    ListSortModel(
        columns: rowColumns, sortColumn: sortColumn,
        sortAscending: ascending)
}

private let twoRows = [
    Row(id: 1, name: "b", count: 2),
    Row(id: 2, name: "a", count: 1),
]

// The reason the selection is an identity and not a row number: five views
// stored the number and none of them repaired it when the order changed, so a
// header tap slid the highlight onto whatever had moved into that slot.
check("model: the selection follows its row through a re-sort") {
    var m = rowModel()
    m.focusedId = 1
    let before = m.ordinal(in: m.sorted(twoRows))
    m.select("count")
    let after = m.ordinal(in: m.sorted(twoRows))
    return before == 1 && after == 0 && m.focusedId == 1
}

check("model: a new column opens in the direction it declared") {
    var m = rowModel()
    m.select("count")
    return m.sortColumn == "count" && !m.sortAscending
}

check("model: picking the same column again reverses it") {
    var m = rowModel()
    m.select("name")
    return !m.sortAscending
}

check("model: tied rows hold their arrival order in both directions") {
    var m = rowModel(sortColumn: "count", ascending: true)
    let tied = [
        Row(id: 1, name: "a", count: 7),
        Row(id: 2, name: "b", count: 7),
        Row(id: 3, name: "c", count: 7),
    ]
    let ascending = m.sorted(tied).map(\.id)
    m.sortAscending = false
    return ascending == [1, 2, 3] && m.sorted(tied).map(\.id) == [1, 2, 3]
}

check("model: a refresh that keeps the row keeps the selection") {
    var m = rowModel()
    m.focusedId = 2
    m.reconcileFocus(in: twoRows, seed: .first)
    return m.focusedId == 2
}

check("model: a selection whose row is gone falls back to the seed") {
    var m = rowModel()
    m.focusedId = 99
    m.reconcileFocus(in: twoRows, seed: .last)
    let seededLast = m.focusedId
    m.focusedId = 99
    m.reconcileFocus(in: twoRows, seed: .first)
    return seededLast == 2 && m.focusedId == 1
}

check("model: an empty refresh clears the selection") {
    var m = rowModel()
    m.focusedId = 1
    m.reconcileFocus(in: [], seed: .first)
    return m.focusedId == nil
}

check("model: moving stops at the ends, and starts from the far one") {
    var m = rowModel(sortColumn: "count", ascending: true)
    let rows = m.sorted(twoRows)  // id 2 then id 1
    m.move(.up, in: rows)
    let fromNothing = m.focusedId
    m.move(.down, in: rows)
    let heldAtBottom = m.focusedId
    m.move(.up, in: rows)
    let movedUp = m.focusedId
    m.move(.up, in: rows)
    return fromNothing == 1 && heldAtBottom == 1 && movedUp == 2
        && m.focusedId == 2
}

check("model: a column title comes from the one place it is declared") {
    rowModel().title(for: "count") == "Count"
}

print(
    failures == 0
        ? "\n✅ all list checks passed"
        : "\n❌ \(failures) list check(s) failed")
exit(failures == 0 ? 0 : 1)
