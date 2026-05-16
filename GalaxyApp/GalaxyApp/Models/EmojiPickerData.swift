import Foundation

/// Categorized emoji entry for the marker picker. Keywords drive
/// the search-field filter (case-insensitive substring match
/// against any keyword OR the emoji literal itself).
struct EmojiEntry: Identifiable, Hashable {
    let emoji: String
    let category: EmojiCategory
    let keywords: [String]

    /// Identity = the emoji literal — guarantees uniqueness in our
    /// curated list and lets ForEach key by it stably.
    var id: String { emoji }
}

/// Display-order categories. Keep small; users are picking a
/// single icon for a marker, not browsing.
enum EmojiCategory: String, CaseIterable, Identifiable {
    case status = "Status"
    case faces = "Faces"
    case objects = "Objects"
    case nature = "Nature"
    case activities = "Activities"
    case symbols = "Symbols"

    var id: String { rawValue }
}

enum EmojiPickerData {
    /// Curated v1 set. Easy to extend without a schema change.
    /// Comprehensive Unicode coverage can be retrofitted later
    /// by swapping the source for a bundled JSON dataset.
    ///
    /// Every entry MUST satisfy the contrast rule: full-color
    /// glyph, recognizable on both light and dark backgrounds.
    /// Reject monochrome / pure-black / pure-white candidates.
    static let allEmojis: [EmojiEntry] = [
        // ----------------------------------------------------------------
        // STATUS — kanban / workflow / dev signals
        // ----------------------------------------------------------------
        EmojiEntry(emoji: "✅", category: .status,
                   keywords: ["check", "done", "complete", "yes", "ok"]),
        EmojiEntry(emoji: "❌", category: .status,
                   keywords: ["x", "no", "fail", "error", "wrong"]),
        EmojiEntry(emoji: "⚠️", category: .status,
                   keywords: ["warning", "caution", "alert"]),
        EmojiEntry(emoji: "🚧", category: .status,
                   keywords: ["wip", "construction", "blocked", "in progress"]),
        EmojiEntry(emoji: "⏳", category: .status,
                   keywords: ["wait", "pending", "hourglass", "later"]),
        EmojiEntry(emoji: "▶️", category: .status,
                   keywords: ["play", "go", "start", "active", "running"]),
        EmojiEntry(emoji: "🚀", category: .status,
                   keywords: ["rocket", "launch", "ship", "deploy", "fast"]),
        EmojiEntry(emoji: "🐛", category: .status,
                   keywords: ["bug", "issue", "defect", "broken"]),
        EmojiEntry(emoji: "🔥", category: .status,
                   keywords: ["fire", "urgent", "hot", "priority", "p0"]),
        EmojiEntry(emoji: "✨", category: .status,
                   keywords: ["sparkles", "new", "feature", "shiny"]),
        EmojiEntry(emoji: "💡", category: .status,
                   keywords: ["idea", "light", "insight", "tip"]),
        EmojiEntry(emoji: "📌", category: .status,
                   keywords: ["pin", "stuck", "important", "fix"]),
        EmojiEntry(emoji: "🎯", category: .status,
                   keywords: ["target", "goal", "focus", "aim"]),
        EmojiEntry(emoji: "🎉", category: .status,
                   keywords: ["celebrate", "party", "done", "shipped"]),
        EmojiEntry(emoji: "🎊", category: .status,
                   keywords: ["confetti", "celebrate", "milestone"]),
        EmojiEntry(emoji: "💯", category: .status,
                   keywords: ["100", "hundred", "perfect", "all in"]),
        EmojiEntry(emoji: "⭐", category: .status,
                   keywords: ["star", "favorite", "important", "starred"]),
        EmojiEntry(emoji: "📝", category: .status,
                   keywords: ["note", "memo", "todo", "draft"]),
        EmojiEntry(emoji: "📋", category: .status,
                   keywords: ["clipboard", "list", "tasks", "backlog"]),
        EmojiEntry(emoji: "🆕", category: .status,
                   keywords: ["new", "fresh", "added"]),
        EmojiEntry(emoji: "🆙", category: .status,
                   keywords: ["up", "upgrade", "improved", "level up"]),
        EmojiEntry(emoji: "🆗", category: .status,
                   keywords: ["ok", "approved", "okay"]),
        EmojiEntry(emoji: "🆓", category: .status,
                   keywords: ["free", "available", "open"]),
        EmojiEntry(emoji: "♻️", category: .status,
                   keywords: ["recycle", "refactor", "redo"]),
        EmojiEntry(emoji: "📅", category: .status,
                   keywords: ["calendar", "date", "schedule", "due"]),
        EmojiEntry(emoji: "⏰", category: .status,
                   keywords: ["alarm", "clock", "deadline", "reminder"]),
        EmojiEntry(emoji: "🏁", category: .status,
                   keywords: ["finish", "done", "checkered flag", "milestone"]),

        // ----------------------------------------------------------------
        // FACES — expressive markers
        // ----------------------------------------------------------------
        EmojiEntry(emoji: "😀", category: .faces,
                   keywords: ["happy", "smile", "grin"]),
        EmojiEntry(emoji: "🙂", category: .faces,
                   keywords: ["smile", "ok", "neutral"]),
        EmojiEntry(emoji: "😊", category: .faces,
                   keywords: ["blush", "happy", "pleased"]),
        EmojiEntry(emoji: "😎", category: .faces,
                   keywords: ["cool", "sunglasses", "boss"]),
        EmojiEntry(emoji: "🤔", category: .faces,
                   keywords: ["think", "thinking", "hmm", "consider"]),
        EmojiEntry(emoji: "👀", category: .faces,
                   keywords: ["eyes", "look", "watching", "see", "review"]),
        EmojiEntry(emoji: "😴", category: .faces,
                   keywords: ["sleep", "tired", "zzz", "dormant"]),
        EmojiEntry(emoji: "🤩", category: .faces,
                   keywords: ["star", "star eyes", "excited", "amazed"]),
        EmojiEntry(emoji: "😍", category: .faces,
                   keywords: ["love", "heart eyes", "favorite", "amazed"]),
        EmojiEntry(emoji: "😅", category: .faces,
                   keywords: ["nervous", "sweat", "phew"]),
        EmojiEntry(emoji: "😢", category: .faces,
                   keywords: ["sad", "cry", "tear"]),
        EmojiEntry(emoji: "😠", category: .faces,
                   keywords: ["angry", "mad", "annoyed"]),
        EmojiEntry(emoji: "😂", category: .faces,
                   keywords: ["laugh", "cry", "joy"]),
        EmojiEntry(emoji: "🤣", category: .faces,
                   keywords: ["rofl", "rolling", "laugh"]),
        EmojiEntry(emoji: "😇", category: .faces,
                   keywords: ["angel", "halo", "innocent"]),
        EmojiEntry(emoji: "🥳", category: .faces,
                   keywords: ["party", "birthday", "celebrate"]),
        EmojiEntry(emoji: "🤯", category: .faces,
                   keywords: ["mind blown", "explode", "wow"]),
        EmojiEntry(emoji: "😱", category: .faces,
                   keywords: ["scream", "shock", "scared"]),
        EmojiEntry(emoji: "🤓", category: .faces,
                   keywords: ["nerd", "geek", "smart"]),
        EmojiEntry(emoji: "🥺", category: .faces,
                   keywords: ["pleading", "begging", "puppy eyes"]),
        EmojiEntry(emoji: "😏", category: .faces,
                   keywords: ["smirk", "sly"]),
        EmojiEntry(emoji: "😬", category: .faces,
                   keywords: ["grimace", "awkward", "yikes"]),
        EmojiEntry(emoji: "🙄", category: .faces,
                   keywords: ["eye roll", "annoyed", "whatever"]),
        EmojiEntry(emoji: "😉", category: .faces,
                   keywords: ["wink", "playful"]),
        EmojiEntry(emoji: "🥹", category: .faces,
                   keywords: ["holding tears", "moved", "touched"]),
        EmojiEntry(emoji: "🫠", category: .faces,
                   keywords: ["melting", "embarrassed", "stressed"]),
        EmojiEntry(emoji: "🤡", category: .faces,
                   keywords: ["clown", "silly", "joke"]),
        EmojiEntry(emoji: "🤖", category: .faces,
                   keywords: ["robot", "bot", "ai", "automated"]),
        EmojiEntry(emoji: "👻", category: .faces,
                   keywords: ["ghost", "spooky", "haunted"]),
        EmojiEntry(emoji: "🤑", category: .faces,
                   keywords: ["money mouth", "money", "greedy", "rich", "dollar"]),

        // ----------------------------------------------------------------
        // OBJECTS — tools / artifacts / hardware
        // ----------------------------------------------------------------
        EmojiEntry(emoji: "📦", category: .objects,
                   keywords: ["box", "package", "release", "shipment"]),
        EmojiEntry(emoji: "📁", category: .objects,
                   keywords: ["folder", "directory"]),
        EmojiEntry(emoji: "📂", category: .objects,
                   keywords: ["folder", "open", "directory"]),
        EmojiEntry(emoji: "📄", category: .objects,
                   keywords: ["document", "file", "page"]),
        EmojiEntry(emoji: "🎨", category: .objects,
                   keywords: ["art", "design", "palette", "ux"]),
        EmojiEntry(emoji: "🔧", category: .objects,
                   keywords: ["wrench", "fix", "tool", "repair"]),
        EmojiEntry(emoji: "🔨", category: .objects,
                   keywords: ["hammer", "build", "tool", "construct"]),
        EmojiEntry(emoji: "⚙️", category: .objects,
                   keywords: ["gear", "settings", "config", "ops"]),
        EmojiEntry(emoji: "🔍", category: .objects,
                   keywords: ["search", "find", "magnify", "review"]),
        EmojiEntry(emoji: "🔑", category: .objects,
                   keywords: ["key", "auth", "access", "secret"]),
        EmojiEntry(emoji: "🔒", category: .objects,
                   keywords: ["lock", "secure", "private", "closed"]),
        EmojiEntry(emoji: "🔓", category: .objects,
                   keywords: ["unlock", "open", "public"]),
        EmojiEntry(emoji: "🧪", category: .objects,
                   keywords: ["test", "experiment", "lab", "qa"]),
        EmojiEntry(emoji: "💻", category: .objects,
                   keywords: ["laptop", "computer", "code", "dev"]),
        EmojiEntry(emoji: "📱", category: .objects,
                   keywords: ["mobile", "phone", "device", "ios"]),
        EmojiEntry(emoji: "🖥", category: .objects,
                   keywords: ["desktop", "monitor", "computer"]),
        EmojiEntry(emoji: "✏️", category: .objects,
                   keywords: ["pencil", "write", "edit", "draft"]),
        EmojiEntry(emoji: "📚", category: .objects,
                   keywords: ["books", "library", "docs", "research"]),
        EmojiEntry(emoji: "📖", category: .objects,
                   keywords: ["book", "read", "manual", "open"]),
        EmojiEntry(emoji: "💾", category: .objects,
                   keywords: ["floppy", "save", "disk", "storage"]),
        EmojiEntry(emoji: "🔋", category: .objects,
                   keywords: ["battery", "power", "energy"]),
        EmojiEntry(emoji: "🧰", category: .objects,
                   keywords: ["toolbox", "tools", "utilities"]),
        EmojiEntry(emoji: "💰", category: .objects,
                   keywords: ["money", "bag", "cash", "wealth", "treasure"]),
        EmojiEntry(emoji: "💵", category: .objects,
                   keywords: ["dollar", "money", "cash", "banknote", "bill"]),
        EmojiEntry(emoji: "💸", category: .objects,
                   keywords: ["money", "flying", "spending", "expense", "loss"]),
        EmojiEntry(emoji: "👛", category: .objects,
                   keywords: ["purse", "money", "wallet", "coins"]),
        EmojiEntry(emoji: "🏧", category: .objects,
                   keywords: ["atm", "money", "bank", "cash", "withdraw"]),
        EmojiEntry(emoji: "📈", category: .objects,
                   keywords: ["chart up", "growth", "increase", "rising", "money"]),
        EmojiEntry(emoji: "📉", category: .objects,
                   keywords: ["chart down", "decrease", "falling", "loss", "money"]),

        // ----------------------------------------------------------------
        // NATURE — color, season, mood
        // ----------------------------------------------------------------
        EmojiEntry(emoji: "🌿", category: .nature,
                   keywords: ["leaf", "plant", "green", "fresh"]),
        EmojiEntry(emoji: "🌳", category: .nature,
                   keywords: ["tree", "nature", "deep"]),
        EmojiEntry(emoji: "🌊", category: .nature,
                   keywords: ["wave", "water", "ocean", "flow"]),
        EmojiEntry(emoji: "☀️", category: .nature,
                   keywords: ["sun", "sunny", "bright", "morning"]),
        EmojiEntry(emoji: "🌙", category: .nature,
                   keywords: ["moon", "night", "dark", "evening"]),
        EmojiEntry(emoji: "⛅", category: .nature,
                   keywords: ["cloud", "weather", "partly", "sky"]),
        EmojiEntry(emoji: "🌈", category: .nature,
                   keywords: ["rainbow", "color", "pride", "spectrum"]),
        EmojiEntry(emoji: "🍀", category: .nature,
                   keywords: ["clover", "luck", "lucky", "four leaf"]),
        EmojiEntry(emoji: "🌸", category: .nature,
                   keywords: ["blossom", "flower", "spring", "cherry"]),
        EmojiEntry(emoji: "🍂", category: .nature,
                   keywords: ["leaves", "autumn", "fall"]),
        EmojiEntry(emoji: "🌻", category: .nature,
                   keywords: ["sunflower", "yellow", "summer"]),
        EmojiEntry(emoji: "🌹", category: .nature,
                   keywords: ["rose", "love", "red"]),
        EmojiEntry(emoji: "🌎", category: .nature,
                   keywords: ["earth", "world", "global"]),
        EmojiEntry(emoji: "🪴", category: .nature,
                   keywords: ["plant", "potted", "growing"]),
        EmojiEntry(emoji: "🌱", category: .nature,
                   keywords: ["seedling", "sprout", "growing", "new"]),
        EmojiEntry(emoji: "🐝", category: .nature,
                   keywords: ["bee", "busy", "buzz"]),

        // ----------------------------------------------------------------
        // ACTIVITIES — sports / music / food
        // ----------------------------------------------------------------
        EmojiEntry(emoji: "🎤", category: .activities,
                   keywords: ["microphone", "music", "audio", "sing"]),
        EmojiEntry(emoji: "🕹", category: .activities,
                   keywords: ["joystick", "game", "controller", "play"]),
        EmojiEntry(emoji: "⚽", category: .activities,
                   keywords: ["soccer", "ball", "sport"]),
        EmojiEntry(emoji: "🏀", category: .activities,
                   keywords: ["basketball", "ball", "sport"]),
        EmojiEntry(emoji: "🎾", category: .activities,
                   keywords: ["tennis", "ball", "sport"]),
        EmojiEntry(emoji: "🏈", category: .activities,
                   keywords: ["football", "ball", "sport"]),
        EmojiEntry(emoji: "🎲", category: .activities,
                   keywords: ["dice", "game", "random", "luck"]),
        EmojiEntry(emoji: "☕", category: .activities,
                   keywords: ["coffee", "tea", "drink", "morning"]),
        EmojiEntry(emoji: "🍕", category: .activities,
                   keywords: ["pizza", "food", "lunch"]),
        EmojiEntry(emoji: "🍺", category: .activities,
                   keywords: ["beer", "drink", "social"]),
        EmojiEntry(emoji: "🎸", category: .activities,
                   keywords: ["guitar", "music", "rock"]),
        EmojiEntry(emoji: "🎷", category: .activities,
                   keywords: ["saxophone", "music", "jazz"]),
        EmojiEntry(emoji: "🏆", category: .activities,
                   keywords: ["trophy", "win", "champion", "best"]),
        EmojiEntry(emoji: "🥇", category: .activities,
                   keywords: ["gold", "medal", "first", "winner"]),
        EmojiEntry(emoji: "🎂", category: .activities,
                   keywords: ["cake", "birthday", "celebrate"]),
        EmojiEntry(emoji: "🍔", category: .activities,
                   keywords: ["burger", "food", "lunch"]),

        // ----------------------------------------------------------------
        // SYMBOLS — hearts / signals / hands
        // ----------------------------------------------------------------
        EmojiEntry(emoji: "❤️", category: .symbols,
                   keywords: ["heart", "love", "favorite"]),
        EmojiEntry(emoji: "💔", category: .symbols,
                   keywords: ["broken", "heart", "sad"]),
        EmojiEntry(emoji: "🆒", category: .symbols,
                   keywords: ["cool", "ok", "approved"]),
        EmojiEntry(emoji: "❓", category: .symbols,
                   keywords: ["question", "ask", "unknown"]),
        EmojiEntry(emoji: "❗", category: .symbols,
                   keywords: ["exclamation", "important", "alert"]),
        EmojiEntry(emoji: "💬", category: .symbols,
                   keywords: ["chat", "comment", "speech", "discuss"]),
        EmojiEntry(emoji: "💭", category: .symbols,
                   keywords: ["thought", "idea", "bubble"]),
        EmojiEntry(emoji: "🌟", category: .symbols,
                   keywords: ["glowing star", "shine", "highlight"]),
        EmojiEntry(emoji: "⚡", category: .symbols,
                   keywords: ["lightning", "fast", "power", "energy"]),
        EmojiEntry(emoji: "🎈", category: .symbols,
                   keywords: ["balloon", "celebrate", "party"]),
        EmojiEntry(emoji: "🎁", category: .symbols,
                   keywords: ["gift", "present", "bonus"]),
        EmojiEntry(emoji: "🔔", category: .symbols,
                   keywords: ["bell", "notify", "alert"]),
        EmojiEntry(emoji: "📣", category: .symbols,
                   keywords: ["megaphone", "announce", "loud"]),
        EmojiEntry(emoji: "📢", category: .symbols,
                   keywords: ["loudspeaker", "announce", "broadcast"]),
        EmojiEntry(emoji: "🚨", category: .symbols,
                   keywords: ["siren", "emergency", "alert", "urgent"]),
        EmojiEntry(emoji: "🛑", category: .symbols,
                   keywords: ["stop", "halt", "blocked"]),
        EmojiEntry(emoji: "⛔", category: .symbols,
                   keywords: ["no entry", "forbidden", "blocked"]),
        EmojiEntry(emoji: "✊", category: .symbols,
                   keywords: ["fist", "solidarity", "power"]),
        EmojiEntry(emoji: "👍", category: .symbols,
                   keywords: ["thumbs up", "yes", "approve", "lgtm"]),
        EmojiEntry(emoji: "👎", category: .symbols,
                   keywords: ["thumbs down", "no", "reject"]),
        EmojiEntry(emoji: "👏", category: .symbols,
                   keywords: ["clap", "applause", "well done"]),
        EmojiEntry(emoji: "🙏", category: .symbols,
                   keywords: ["pray", "thanks", "please"]),
        EmojiEntry(emoji: "🫶", category: .symbols,
                   keywords: ["heart hands", "love", "care"]),
        EmojiEntry(emoji: "❤️‍🔥", category: .symbols,
                   keywords: ["heart on fire", "passion", "love"]),
        EmojiEntry(emoji: "💖", category: .symbols,
                   keywords: ["sparkling heart", "love", "pink"]),
        EmojiEntry(emoji: "💕", category: .symbols,
                   keywords: ["two hearts", "love", "pink"]),
    ]

    /// Filtered view, partitioned by category, preserving display
    /// order. Empty `query` returns all emojis. Search is
    /// case-insensitive substring against any keyword OR the
    /// literal.
    static func filtered(
        by query: String
    ) -> [(EmojiCategory, [EmojiEntry])] {
        let q = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let pool: [EmojiEntry] =
            q.isEmpty
            ? allEmojis
            : allEmojis.filter { entry in
                if entry.emoji.lowercased().contains(q) { return true }
                return entry.keywords.contains(where: {
                    $0.lowercased().contains(q)
                })
            }
        return EmojiCategory.allCases.compactMap { category in
            let entries = pool.filter { $0.category == category }
            return entries.isEmpty ? nil : (category, entries)
        }
    }
}
