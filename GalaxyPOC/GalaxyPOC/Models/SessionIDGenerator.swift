import Foundation

/// Generates human-readable session IDs using random words
/// Format: adjective-noun-verb (e.g., "swift-falcon-soars")
struct SessionIDGenerator {

    static func generate() -> String {
        let adjective = adjectives.randomElement() ?? "quick"
        let noun = nouns.randomElement() ?? "fox"
        let verb = verbs.randomElement() ?? "runs"
        return "\(adjective)-\(noun)-\(verb)"
    }

    // ~200 adjectives - simple, short, easy to read
    private static let adjectives = [
        "able", "aged", "azure", "bare", "bold", "brave", "brief", "bright", "broad", "calm",
        "clean", "clear", "close", "cold", "cool", "crisp", "dark", "dear", "deep", "dense",
        "dry", "dull", "eager", "early", "easy", "even", "fair", "false", "fast", "fine",
        "firm", "flat", "fond", "free", "fresh", "full", "glad", "gold", "good", "grand",
        "gray", "great", "green", "half", "happy", "hard", "harsh", "heavy", "high", "hollow",
        "hot", "huge", "humble", "ideal", "idle", "iron", "jolly", "keen", "kind", "large",
        "last", "late", "lazy", "lean", "left", "light", "live", "long", "loose", "lost",
        "loud", "low", "lucky", "mad", "magic", "main", "major", "merry", "mild", "minor",
        "misty", "modern", "moist", "narrow", "near", "neat", "new", "nice", "noble", "north",
        "odd", "old", "open", "orange", "outer", "pale", "past", "plain", "poor", "prime",
        "proud", "pure", "quick", "quiet", "rare", "raw", "ready", "real", "red", "rich",
        "right", "ripe", "rocky", "rough", "round", "royal", "rusty", "sad", "safe", "salty",
        "same", "sandy", "sharp", "shiny", "short", "shy", "silent", "silver", "simple", "single",
        "slim", "slow", "small", "smart", "smooth", "snowy", "soft", "solid", "sour", "south",
        "spare", "stark", "steady", "steep", "still", "stony", "stormy", "strange", "strict", "strong",
        "sudden", "sunny", "super", "sure", "sweet", "swift", "tall", "tame", "tart", "tender",
        "thick", "thin", "tight", "tiny", "tired", "tough", "true", "vague", "valid", "vast",
        "vivid", "warm", "weak", "wet", "white", "whole", "wide", "wild", "windy", "wise",
        "wooden", "wrong", "yellow", "young", "zesty", "able", "active", "agile", "alert", "alive",
        "ancient", "annual", "basic", "bitter", "blank", "blind", "blue", "blunt", "bored", "brown"
    ]

    // ~200 nouns - concrete, easy to visualize
    private static let nouns = [
        "ace", "ant", "ape", "apple", "arch", "arm", "badge", "ball", "bank", "barn",
        "base", "bath", "bay", "beach", "bead", "beam", "bean", "bear", "beast", "bed",
        "bell", "belt", "bench", "bird", "blade", "block", "bloom", "board", "boat", "bolt",
        "bone", "book", "boot", "boss", "bow", "bowl", "box", "brain", "branch", "brass",
        "bread", "brick", "bridge", "brook", "brush", "bulk", "bush", "cabin", "cake", "camp",
        "cape", "card", "cart", "case", "castle", "cave", "chain", "chair", "chalk", "charm",
        "chest", "chip", "clam", "clay", "cliff", "clock", "cloth", "cloud", "clover", "club",
        "coach", "coal", "coast", "coat", "coin", "comet", "cone", "coral", "cord", "cork",
        "corn", "couch", "crab", "crane", "creek", "crest", "crow", "crown", "cube", "cup",
        "dart", "dawn", "deer", "desk", "dew", "disk", "dock", "dome", "door", "dove",
        "dream", "drum", "duck", "dune", "dust", "eagle", "ear", "edge", "elm", "ember",
        "eye", "face", "falcon", "farm", "fawn", "feast", "fence", "fern", "field", "fig",
        "finch", "fire", "fish", "flag", "flame", "flask", "flock", "flood", "floor", "flower",
        "flute", "foam", "fog", "foot", "ford", "forge", "fork", "fort", "fox", "frame",
        "frost", "fruit", "gate", "gear", "gem", "ghost", "gift", "glade", "glass", "glen",
        "globe", "glove", "goat", "gold", "grape", "grass", "grove", "guard", "guide", "gulf",
        "gust", "hall", "hand", "harbor", "hare", "harp", "harvest", "hat", "hawk", "hay",
        "heart", "hedge", "helm", "hero", "hill", "hive", "hook", "hope", "horn", "horse",
        "house", "hut", "ice", "inn", "iron", "island", "ivy", "jade", "jar", "jay",
        "jewel", "judge", "jungle", "kelp", "key", "kite", "knot", "lake", "lamp", "lance"
    ]

    // ~200 verbs - action words, easy to understand
    private static let verbs = [
        "acts", "adds", "aims", "asks", "bakes", "barks", "beams", "bears", "beats", "bends",
        "bites", "blasts", "blazes", "blends", "blinks", "blooms", "blows", "bolts", "bonds", "bounds",
        "bows", "brews", "brings", "builds", "burns", "bursts", "buys", "calls", "calms", "camps",
        "cares", "carves", "casts", "catches", "chants", "charms", "chases", "cheers", "chills", "chimes",
        "chirps", "claims", "claps", "clears", "clicks", "climbs", "clings", "clips", "coasts", "coils",
        "comes", "cools", "counts", "crafts", "crawls", "creates", "creeps", "cries", "crosses", "curls",
        "cuts", "dances", "dares", "darts", "dashes", "dawns", "deals", "digs", "dims", "dips",
        "dives", "does", "dots", "drags", "drains", "draws", "dreams", "drifts", "drills", "drinks",
        "drips", "drives", "drops", "drums", "ducks", "dusts", "earns", "eats", "ebbs", "edges",
        "ends", "enters", "escapes", "eyes", "faces", "fades", "fails", "falls", "farms", "fears",
        "feasts", "feeds", "feels", "fights", "fills", "finds", "fires", "fits", "fixes", "flags",
        "flaps", "flares", "flashes", "flees", "flicks", "flies", "flips", "floats", "floods", "flows",
        "folds", "follows", "forges", "forms", "frees", "freezes", "gains", "gasps", "gazes", "gets",
        "gives", "glares", "gleams", "glides", "glints", "glows", "goes", "grabs", "grants", "grasps",
        "greets", "grins", "grips", "groans", "grows", "guards", "guides", "gulps", "halts", "hands",
        "hangs", "harps", "hastes", "hauls", "heals", "heaps", "hears", "heats", "heaves", "helps",
        "hides", "hints", "hits", "holds", "hooks", "hopes", "hops", "hosts", "howls", "hugs",
        "hums", "hunts", "hurls", "joins", "jolts", "jumps", "keeps", "kicks", "kneels", "knits",
        "knows", "lands", "lasts", "laughs", "leads", "leaps", "learns", "leaves", "lends", "lifts",
        "lights", "links", "lists", "lives", "loads", "locks", "logs", "looks", "loops", "loves"
    ]
}
