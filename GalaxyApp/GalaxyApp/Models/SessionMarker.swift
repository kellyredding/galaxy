import Foundation
import Combine

/// A user-defined section delimiter in the sidebar. Pure metadata —
/// no terminal, no process, no ledger linkage. Persists alongside
/// sessions in sessions.json. Reorderable via the same drag handle
/// as Session rows; height matches a session row exactly so the
/// drag coordinator's uniform-height math stays valid.
class SessionMarker: Identifiable, ObservableObject {
    let id: UUID

    /// Free-form display text. Empty string is allowed and renders
    /// as just the flanking horizontal lines (no text). Trimmed at
    /// commit time in the inline editor.
    @Published var name: String

    /// User-assigned emoji. Empty string = no emoji (the marker
    /// renders without a leading glyph). Otherwise a single
    /// grapheme cluster (the picker only emits whole emoji
    /// graphemes; modifiers like skin tones come along as part
    /// of the cluster).
    @Published var emoji: String

    init(name: String = "", emoji: String = "") {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
    }

    /// Restore from persisted state — preserves the existing UUID
    /// so sidebar order references remain valid across launches.
    /// `emoji` defaults to empty when absent in the persisted
    /// payload (markers created before the emoji feature shipped).
    init(restoring state: PersistedSessionMarker) {
        self.id = state.id
        self.name = state.name
        self.emoji = state.emoji ?? ""
    }

    func toPersistedState() -> PersistedSessionMarker {
        PersistedSessionMarker(id: id, name: name, emoji: emoji)
    }
}
