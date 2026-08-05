import Foundation

/// One sortable column: what it is called, how to order by it, and which
/// direction reads as natural when a reader first picks it.
///
/// The comparator is a closure rather than a key path because not every key is
/// stored. The ledger's Ops column is synthesized from four Bool fields, and a
/// key path cannot reach a value that does not exist until it is asked for.
/// A derived key is therefore rebuilt on each comparison, which at the sizes
/// these lists reach is not worth a caching layer to avoid.
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

/// Sort order and selection for one list view.
///
/// Selection is held as an element identity, not as an index into the sorted
/// array. That is the whole point of the type: five views each stored an `Int`
/// ordinal and none of them fixed it up when the order changed, so clicking a
/// column header moved the highlight onto an unrelated record. An identity
/// cannot be invalidated by reordering, and the ordinal it implies is a lookup
/// away when the keyboard or the scroller needs one.
struct ListSortModel<Element: Identifiable, Column: Hashable> {
    private let columns: [ListColumn<Element, Column>]

    var sortColumn: Column
    var sortAscending: Bool
    var focusedId: Element.ID?

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

    func sorted(_ elements: [Element]?) -> [Element] {
        guard let elements = elements else { return [] }
        guard
            let descriptor = columns.first(where: {
                $0.column == sortColumn
            })
        else { return elements }

        // Sorted by arrival position when the keys tie, in both directions, so
        // rows sharing a value hold still instead of taking whatever order the
        // sort happened to leave them in.
        return elements.enumerated().sorted { lhs, rhs in
            let order = descriptor.compare(lhs.element, rhs.element)
            if order == .orderedSame { return lhs.offset < rhs.offset }
            return ListSorting.ordered(order, ascending: sortAscending)
        }
        .map(\.element)
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
    }

    // MARK: - Selection

    /// Settle the selection against a new set of rows.
    ///
    /// The selected row keeps the highlight if it is still there, which is the
    /// ordinary outcome of a refresh and the thing four of these views used to
    /// throw away by resetting to a fixed position every time.
    mutating func reconcileFocus(in elements: [Element], seed: Seed) {
        if let id = focusedId,
            elements.contains(where: { $0.id == id })
        {
            return
        }
        guard !elements.isEmpty else {
            focusedId = nil
            return
        }
        focusedId = seed == .first
            ? elements.first?.id
            : elements.last?.id
    }

    func ordinal(in elements: [Element]) -> Int? {
        guard let id = focusedId else { return nil }
        return elements.firstIndex { $0.id == id }
    }

    func focusedElement(in elements: [Element]) -> Element? {
        guard let id = focusedId else { return nil }
        return elements.first { $0.id == id }
    }

    /// Move the selection one row. Stops at either end rather than wrapping,
    /// and starts from the far end when nothing is selected yet.
    mutating func move(_ direction: Direction, in elements: [Element]) {
        guard !elements.isEmpty else { return }
        guard let current = ordinal(in: elements) else {
            focusedId = direction == .up
                ? elements.last?.id
                : elements.first?.id
            return
        }
        switch direction {
        case .up:
            guard current > 0 else { return }
            focusedId = elements[current - 1].id
        case .down:
            guard current < elements.count - 1 else { return }
            focusedId = elements[current + 1].id
        }
    }
}
