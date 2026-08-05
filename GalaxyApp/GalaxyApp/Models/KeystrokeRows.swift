import Foundation
import Galactic

/// Galaxy's side of the ⌘/ cheat sheet: the catalog, resolved into the rows
/// Galactic draws.
///
/// Above this line is app knowledge — which keys exist, what they are
/// called, when they are live. Below it is mechanism: search, highlighting,
/// layout, dismissal. Rows cross already resolved, so `CheatSheetView`
/// never learns what a `SessionTab` is and `KeystrokeCatalog` never learns
/// what a `View` is.
///
/// Deliberately not under `Models/Keystrokes/`, for the same reason
/// `KeystrokeBindingResolver` is not: it imports Galactic, and that
/// directory is the Foundation-only surface `KeystrokeSmoke` compiles.
/// Keeping the builder one level up is what keeps the catalog checkable.
enum KeystrokeRows {

    /// Every documented keystroke as a row, grouped into the sections that
    /// have any, against one snapshot.
    ///
    /// A row is one keystroke, not one command: a configurable action can
    /// carry several, and the catalog already writes ⌘H and ⌘← as two rows
    /// for one command, so listing each key on its own line is the shape
    /// that was already here. The alternative, stacking them into one
    /// cell, would blow out a column every other row is aligned to.
    ///
    /// No filtering happens here, and that is deliberate. The view owns
    /// the search field, so it owns the filter — and it needs the
    /// unfiltered set to say "N of M" at all.
    static func sections(for ctx: KeystrokeContext) -> [CheatSheetSection] {
        let opening = KeystrokeSection.opening(for: ctx)
        var bySection: [KeystrokeSection: [CheatSheetRow]] = [:]

        for (index, entry) in KeystrokeCatalog.all.enumerated() {
            // Both read once per entry rather than once per rendered row.
            // Availability is a function of the snapshot alone, and the
            // snapshot cannot change while the sheet is up.
            let isActive = entry.availability.isActive(in: ctx)
            let condition = entry.availability.conditionText

            let keys = KeystrokeBindingResolver.displayTexts(
                for: entry.binding)
            for (keyIndex, text) in keys.enumerated() {
                let row = CheatSheetRow(
                    // The catalog index and the key's place within its
                    // entry. Either alone can repeat; together they
                    // cannot, so two configured keystrokes that render
                    // alike still get their own identity rather than
                    // colliding in one container.
                    id: "\(index).\(keyIndex)"
                        + "|\(entry.section.rawValue)|\(text)",
                    keys: text,
                    label: entry.label,
                    condition: condition,
                    isActive: isActive,
                    // The authored synonyms only. This row's own glyphs,
                    // spelled out, are derived from `keys` on the other
                    // side — where a row cannot ship without them.
                    aliases: entry.aliases)
                bySection[entry.section, default: []].append(row)
            }
        }

        // `allCases` order, not catalog order, so the sheet's headings
        // keep their authored sequence. A section with nothing authored
        // into it is dropped here so the sheet never shows a bare header;
        // a section the *query* empties is dropped over there, for the
        // same reason on different evidence.
        return KeystrokeSection.allCases.compactMap { section in
            guard let rows = bySection[section], !rows.isEmpty else {
                return nil
            }
            return CheatSheetSection(
                id: section.rawValue,
                title: section.title,
                rows: rows,
                isOpening: section == opening)
        }
    }
}
