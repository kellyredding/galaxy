import Foundation

/// One sortable column: what it is called, how to order by it, and which
/// direction reads as natural when a reader first picks it.
///
/// The comparator is a closure rather than a key path because not every key is
/// stored. The ledger's Ops column is synthesized from four Bool fields, and a
/// key path cannot reach a value that does not exist until it is asked for.
/// A derived key is therefore rebuilt on each comparison, which is affordable
/// only because the sort now runs once per data change rather than once per
/// read — see `ListSortModel`.
struct ListColumn<Element, Column: Hashable> {
    let column: Column
    let title: String
    let compare: (Element, Element) -> ComparisonResult

    /// Direction applied when this column is newly selected.
    ///
    /// Three views wrote this rule three different ways and two of them
    /// disagreed about the same kind of column, so here it is stated per
    /// column instead of buried in a header handler.
    let prefersAscending: Bool

    init(
        _ column: Column,
        title: String,
        prefersAscending: Bool = true,
        compare: @escaping (Element, Element) -> ComparisonResult
    ) {
        self.column = column
        self.title = title
        self.prefersAscending = prefersAscending
        self.compare = compare
    }
}

/// Sort order, selection, and the ordered rows themselves for one list view.
///
/// **The model owns the order.** Five views each derived it from a computed
/// property, so the sort ran on every access — several times per body pass,
/// plus once more in each fetch completion — over arrays reaching fifteen
/// hundred multi-`String` structs, through an ICU collation whenever the
/// selected column was textual. Order can change on exactly two events, so it
/// is computed on exactly those two and stored.
///
/// The same move closes a second hole: the selection APIs used to take the
/// array to act on, and three callers passed a freshly re-sorted copy rather
/// than the one on screen. Nothing takes an array now, so nothing can pass the
/// wrong one.
///
/// Selection is held as an element identity, not as an index into the sorted
/// array. That is the other half of the type's point: five views each stored an
/// `Int` ordinal and none of them fixed it up when the order changed, so
/// clicking a column header moved the highlight onto an unrelated record. An
/// identity cannot be invalidated by reordering, and the ordinal it implies is
/// a lookup away when the keyboard or the scroller needs one.
struct ListSortModel<Element: Identifiable, Column: Hashable> {
    private let columns: [ListColumn<Element, Column>]

    /// Read by a header to draw its chevron. Settable only through `select` and
    /// `reverse`, so no caller can change the order without the rows being
    /// recomputed to match it.
    private(set) var sortColumn: Column
    private(set) var sortAscending: Bool

    var focusedId: Element.ID?

    /// Arrival order, exactly as the fetch handed it over.
    ///
    /// Kept alongside the display order because the tie-break is arrival
    /// position: re-sorting from the previous *display* order would make ties
    /// break by whichever column was selected before it, so picking Type and
    /// then Status would order Status's ties by Type. Every sort starts here.
    private var arrived: [Element] = []

    /// The display order. Recomputed on a data change or a header tap, never on
    /// a read.
    private(set) var rows: [Row] = []

    /// One row on screen: an element and its position in the display order.
    ///
    /// The offset is carried rather than derived at render time because the one
    /// thing that wanted it was zebra striping, and getting it with
    /// `Array(rows.enumerated())` allocated a tuple per row on every body pass.
    struct Row: Identifiable {
        let offset: Int
        let element: Element
        var id: Element.ID { element.id }
    }

    /// What the order currently is, as a value.
    ///
    /// Exists so a fetch can carry the order off the main actor, sort there,
    /// and hand the result back — see `adopt`. Equatable so a landing fetch can
    /// be asked whether the order it sorted for is still the one in effect.
    struct Order: Equatable {
        let column: Column
        let ascending: Bool
    }

    var order: Order {
        Order(column: sortColumn, ascending: sortAscending)
    }

    init(
        columns: [ListColumn<Element, Column>],
        sortColumn: Column,
        sortAscending: Bool
    ) {
        self.columns = columns
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
    }

    /// Which end of the list a fresh selection starts from.
    enum Seed { case first, last }

    enum Direction { case up, down }

    func title(for column: Column) -> String {
        columns.first { $0.column == column }?.title ?? ""
    }

    // MARK: - Order

    /// Sort without a model instance, so a caller off the main actor can.
    ///
    /// Static and pure for that reason alone: the fetches feeding the three
    /// large lists sort here before hopping back, which is the only sort in
    /// these views big enough to be worth moving.
    ///
    /// The tie-break is the enumerated offset of `elements`, which is arrival
    /// position — see `arrived`.
    static func sort(
        _ elements: [Element],
        by order: Order,
        columns: [ListColumn<Element, Column>]
    ) -> [Element] {
        guard
            let descriptor = columns.first(where: {
                $0.column == order.column
            })
        else { return elements }

        // Sorted by arrival position when the keys tie, in both directions, so
        // rows sharing a value hold still instead of taking whatever order the
        // sort happened to leave them in.
        return elements.enumerated().sorted { lhs, rhs in
            let result = descriptor.compare(lhs.element, rhs.element)
            if result == .orderedSame { return lhs.offset < rhs.offset }
            return ListSorting.ordered(result, ascending: order.ascending)
        }
        .map(\.element)
    }

    /// Take a fetch's rows and order them here.
    mutating func setElements(_ elements: [Element]?) {
        arrived = elements ?? []
        resort()
    }

    /// Take a fetch's rows that have already been sorted elsewhere.
    ///
    /// `presorted` is the order they were sorted for. It is trusted only while
    /// it still matches: a reader who taps a header while the fetch is in
    /// flight leaves the incoming order stale, and re-sorting here is both the
    /// correct answer and the rare one. Passing nil re-sorts unconditionally.
    mutating func adopt(
        _ elements: [Element],
        sorted: [Element],
        presortedFor presorted: Order?
    ) {
        arrived = elements
        if presorted == order {
            rows = Self.indexed(sorted)
        } else {
            resort()
        }
    }

    /// Answer a header tap: the same column reverses, a new one starts in the
    /// direction it declared.
    mutating func select(_ column: Column) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending =
                columns.first { $0.column == column }?
                .prefersAscending ?? true
        }
        resort()
    }

    /// Reverse the current column.
    ///
    /// Separate from `select` so a caller holding a direction does not have to
    /// know whether tapping this column would toggle it or move to it.
    mutating func reverse() {
        sortAscending.toggle()
        resort()
    }

    private mutating func resort() {
        rows = Self.indexed(
            Self.sort(arrived, by: order, columns: columns)
        )
    }

    private static func indexed(_ elements: [Element]) -> [Row] {
        elements.enumerated().map {
            Row(offset: $0.offset, element: $0.element)
        }
    }

    // MARK: - Selection

    /// Settle the selection against the rows now on screen.
    ///
    /// The selected row keeps the highlight if it is still there, which is the
    /// ordinary outcome of a refresh and the thing four of these views used to
    /// throw away by resetting to a fixed position every time.
    ///
    /// Takes no array: it reads the order this model just computed, which is
    /// the order the reader is looking at.
    mutating func reconcileFocus(seed: Seed) {
        if let id = focusedId, rows.contains(where: { $0.id == id }) {
            return
        }
        guard !rows.isEmpty else {
            focusedId = nil
            return
        }
        focusedId = seed == .first ? rows.first?.id : rows.last?.id
    }

    func ordinal() -> Int? {
        guard let id = focusedId else { return nil }
        return rows.firstIndex { $0.id == id }
    }

    func focusedElement() -> Element? {
        guard let id = focusedId else { return nil }
        return rows.first { $0.id == id }?.element
    }

    /// Move the selection one row. Stops at either end rather than wrapping,
    /// and starts from the far end when nothing is selected yet.
    mutating func move(_ direction: Direction) {
        guard !rows.isEmpty else { return }
        guard let current = ordinal() else {
            focusedId = direction == .up ? rows.last?.id : rows.first?.id
            return
        }
        switch direction {
        case .up:
            guard current > 0 else { return }
            focusedId = rows[current - 1].id
        case .down:
            guard current < rows.count - 1 else { return }
            focusedId = rows[current + 1].id
        }
    }
}
