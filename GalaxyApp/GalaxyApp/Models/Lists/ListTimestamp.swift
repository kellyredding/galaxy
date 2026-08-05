import Foundation

/// The one timestamp policy for Galaxy's lists and detail panes.
///
/// Six views each carried their own parser stack for this, and they agreed on
/// neither the parse set nor the output: the same instant read as
/// "3/30/25, 4:03:12 PM" on one tab and "Mar 30, 2025 at 4:03 PM" on the next,
/// while a third spelled it relatively. One of the six had lost its SQLite
/// branch entirely and would have printed a raw string had it ever been handed
/// one.
///
/// Tiered rather than absolute because every list this feeds answers "what
/// happened in this session", where recency is the thing being scanned and a
/// full date on every row is column width spent on the year.
///
/// Formatters are not safe to use from two threads at once. Every caller is a
/// view body, so every caller is already on the main actor.
enum ListTimestamp {
    /// What the CLIs write: SQLite's `datetime('now')`, UTC, no offset and no
    /// fractional part. Effectively every timestamp in the app.
    ///
    /// `en_US_POSIX` because the input is a fixed machine format. A
    /// locale-sensitive parser fails outright under a non-Gregorian system
    /// calendar, and the failure mode is the raw string on screen.
    private static let sqlite: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// The ledger's `last_attempt_at` is written as RFC3339 instead, and is
    /// the only value in the app that is.
    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Kept because the views being replaced accepted it. No producer emits
    /// it today, and `ISO8601DateFormatter` rejects fractional input on the
    /// plain option set, so tolerating both takes two formatters.
    private static let rfc3339Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        return f
    }()

    /// How much of the date is worth printing, given how long ago it was.
    enum Tier {
        case today, thisWeek, thisYear, older

        var dateFormat: String {
            switch self {
            case .today: return "h:mm a"
            case .thisWeek: return "EEE h:mm a"
            case .thisYear: return "MMM d, h:mm a"
            case .older: return "MMM d, yyyy, h:mm a"
            }
        }
    }

    /// One formatter per tier, built once.
    ///
    /// Deliberately locale-sensitive, unlike the parsers: the output is for a
    /// reader. Building these per call — which the agents list did, once per
    /// visible row per render — pays for an ICU pattern rebuild each time.
    private static let displayFormatters: [Tier: DateFormatter] = {
        var built: [Tier: DateFormatter] = [:]
        for tier in [Tier.today, .thisWeek, .thisYear, .older] {
            let f = DateFormatter()
            f.dateFormat = tier.dateFormat
            f.timeZone = .current
            built[tier] = f
        }
        return built
    }()

    static func parse(_ timestamp: String) -> Date? {
        if let date = sqlite.date(from: timestamp) { return date }
        if let date = rfc3339.date(from: timestamp) { return date }
        return rfc3339Fractional.date(from: timestamp)
    }

    /// `now` and `calendar` are arguments rather than reads of the clock so
    /// the tier boundaries can be asserted.
    static func tier(
        for date: Date, now: Date, calendar: Calendar
    ) -> Tier {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let weekAgo = calendar.date(
            byAdding: .day, value: -6, to: now
        ), date >= weekAgo {
            return .thisWeek
        }
        if calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        {
            return .thisYear
        }
        return .older
    }

    static func format(
        _ timestamp: String, now: Date, calendar: Calendar
    ) -> String {
        guard let date = parse(timestamp) else { return timestamp }
        let tier = tier(for: date, now: now, calendar: calendar)
        return displayFormatters[tier]?.string(from: date) ?? timestamp
    }

    /// A relative reading goes stale in a window left open across midnight.
    /// These lists re-render on every fetch, tab switch and sort, so the
    /// window is short enough not to be worth a timer.
    static func format(_ timestamp: String) -> String {
        format(timestamp, now: Date(), calendar: .current)
    }
}
