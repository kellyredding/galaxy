import Foundation

// Sandboxed smoke check for turn pairing. Runs as its own process — no
// app, no window, no query service. Run via `make smoke`. Exits
// non-zero if any check fails.
//
// It exists because two surfaces render these pairs — the Ledger's Last
// activity sub-tab and a stopped session's history panel — and until
// this file there was nowhere either of them could be checked. The
// pairing lived inside a `View` struct, reachable only by the app.
//
// What is asserted here is what a reader of those views cannot check by
// reading: which half of a pair supplies the prompt when the other half
// is missing, that a payload the recorder truncated is reported rather
// than silently dropped, and which end of the returned list is the
// newest turn.
//
// What this does NOT check, stated plainly: anything with a pixel in
// it. Panel height, glyph choice and truncation width stay per-view.

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

/// A Gregorian UTC calendar, built rather than borrowed from the
/// environment so a check means the same thing on any machine.
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!

func at(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
) -> Date {
    utc.date(
        from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second))!
}

var nextId: Int64 = 0

func event(
    _ eventType: String,
    turn: String?,
    detail: String?,
    at when: Date = at(2026, 9, 8, 12)
) -> TimelineEvent {
    nextId += 1
    return TimelineEvent(
        id: nextId,
        eventType: eventType,
        occurredAt: when,
        source: "smoke",
        durationIdentifier: turn.map { "turn--\($0)" },
        detailData: detail,
        createdAt: "2026-09-08 12:00:00",
        updatedAt: "2026-09-08 12:00:00")
}

/// The CLI is always asked with `--reverse`, so a fixture list is
/// newest first. Built here in that order on purpose — a fixture that
/// reads oldest-first would let a reversed implementation pass.
func initiated(_ turn: String, _ message: String) -> TimelineEvent {
    event(
        "turn:initiated", turn: turn,
        detail: #"{"user_message":"\#(message)"}"#)
}

func completed(
    _ turn: String, _ message: String, _ response: String
) -> TimelineEvent {
    event(
        "turn:completed", turn: turn,
        detail: """
            {"user_message":"\(message)",\
            "assistant_response":"\(response)"}
            """)
}

// MARK: - Pairing

check("pairing: an initiated and its end become one pair") {
    let pairs = TurnPairing.pairs(
        from: [completed("a", "ask", "answer"), initiated("a", "ask")],
        limit: 5, order: .chronological)
    guard pairs.count == 1 else { return false }
    return pairs[0].userMessage == .text("ask")
        && pairs[0].assistantResponse == .text("answer")
        && pairs[0].initiatedEvent != nil
}

check("pairing: a pair is identified by its end event") {
    let end = completed("a", "ask", "answer")
    let pairs = TurnPairing.pairs(
        from: [end, initiated("a", "ask")],
        limit: 5, order: .chronological)
    return pairs.first?.id == end.id
}

// The reason the prompt is read from the end event first. Asking for
// the most recent N turns cuts the window at an arbitrary point, so the
// oldest pair in view routinely has no `turn:initiated` — and
// `turn:completed` carries the prompt too.
check("pairing: a pair with no initiated half still shows the prompt") {
    let pairs = TurnPairing.pairs(
        from: [completed("a", "ask", "answer")],
        limit: 5, order: .chronological)
    guard pairs.count == 1 else { return false }
    return pairs[0].initiatedEvent == nil
        && pairs[0].userMessage == .text("ask")
}

check("pairing: an initiated with no end is not a turn yet") {
    TurnPairing.pairs(
        from: [initiated("a", "ask")],
        limit: 5, order: .chronological
    ).isEmpty
}

check("pairing: an initiated carrying no turn id is dropped") {
    let orphan = event(
        "turn:initiated", turn: nil,
        detail: #"{"user_message":"ask"}"#)
    return TurnPairing.pairs(
        from: [orphan], limit: 5, order: .chronological
    ).isEmpty
}

// `turn:interrupted` is recorded by SessionManager when Esc lands
// mid-turn, and it carries no response. That is a different fact from a
// response the recorder truncated, and the panel says so differently.
check("pairing: an interrupted turn has an absent response") {
    let interrupted = event(
        "turn:interrupted", turn: "a",
        detail: #"{"user_message":"ask"}"#)
    let pairs = TurnPairing.pairs(
        from: [interrupted, initiated("a", "ask")],
        limit: 5, order: .chronological)
    guard pairs.count == 1 else { return false }
    return pairs[0].assistantResponse == .absent
        && pairs[0].userMessage == .text("ask")
}

// MARK: - Order

check("order: chronological puts the oldest pair first") {
    let pairs = TurnPairing.pairs(
        from: [
            completed("c", "third", "3"), initiated("c", "third"),
            completed("b", "second", "2"), initiated("b", "second"),
            completed("a", "first", "1"), initiated("a", "first"),
        ],
        limit: 5, order: .chronological)
    return pairs.map(\.userMessage)
        == [.text("first"), .text("second"), .text("third")]
}

check("order: reverse chronological puts the newest pair first") {
    let pairs = TurnPairing.pairs(
        from: [
            completed("c", "third", "3"), initiated("c", "third"),
            completed("b", "second", "2"), initiated("b", "second"),
            completed("a", "first", "1"), initiated("a", "first"),
        ],
        limit: 5, order: .reverseChronological)
    return pairs.map(\.userMessage)
        == [.text("third"), .text("second"), .text("first")]
}

// The limit has to bite before the reversal, or asking for the most
// recent two would hand back the oldest two.
check("order: the limit keeps the newest, whichever way the list reads") {
    let events = [
        completed("c", "third", "3"), initiated("c", "third"),
        completed("b", "second", "2"), initiated("b", "second"),
        completed("a", "first", "1"), initiated("a", "first"),
    ]
    let chrono = TurnPairing.pairs(
        from: events, limit: 2, order: .chronological)
    let reverse = TurnPairing.pairs(
        from: events, limit: 2, order: .reverseChronological)
    return chrono.map(\.userMessage)
        == [.text("second"), .text("third")]
        && reverse.map(\.userMessage)
        == [.text("third"), .text("second")]
}

// MARK: - Truncated records

// The defect this enum exists for. The ledger hooks spawn the timeline
// recorder without waiting, so a payload past the pipe buffer arrives
// cut mid-string. 19 such rows are in the live database. Read through
// `try?` into a nil, they render as blank space on the one screen whose
// whole job is to show what was said.
check("truncated: a payload cut mid-string is unreadable, not absent") {
    let cut = event(
        "turn:completed", turn: "a",
        detail: #"{"user_message":"ask","assistant_response":"answ"#)
    let pairs = TurnPairing.pairs(
        from: [cut], limit: 5, order: .chronological)
    guard pairs.count == 1 else { return false }
    return pairs[0].assistantResponse == .unreadable
        && pairs[0].userMessage == .unreadable
}

check("truncated: a readable half is preferred over a truncated one") {
    let cut = event(
        "turn:completed", turn: "a",
        detail: #"{"user_message":"ask","assistant_response":"answ"#)
    let pairs = TurnPairing.pairs(
        from: [cut, initiated("a", "ask")],
        limit: 5, order: .chronological)
    guard pairs.count == 1 else { return false }
    // The end event is read first and is truncated; the initiated half
    // still has the prompt, and that is what a reader should get.
    return pairs[0].userMessage == .text("ask")
        && pairs[0].assistantResponse == .unreadable
}

check("truncated: a field the payload never had is absent") {
    let noResponse = event(
        "turn:completed", turn: "a",
        detail: #"{"user_message":"ask"}"#)
    let pairs = TurnPairing.pairs(
        from: [noResponse], limit: 5, order: .chronological)
    return pairs.first?.assistantResponse == .absent
}

check("truncated: an empty string field is absent, not empty text") {
    let empty = event(
        "turn:completed", turn: "a",
        detail: #"{"user_message":"ask","assistant_response":""}"#)
    let pairs = TurnPairing.pairs(
        from: [empty], limit: 5, order: .chronological)
    return pairs.first?.assistantResponse == .absent
}

check("truncated: a missing payload is absent, not unreadable") {
    let pairs = TurnPairing.pairs(
        from: [event("turn:completed", turn: "a", detail: nil)],
        limit: 5, order: .chronological)
    guard pairs.count == 1 else { return false }
    return pairs[0].userMessage == .absent
        && pairs[0].assistantResponse == .absent
}

// A JSON document that parses but is not an object — the recorder
// writes objects, so anything else means the record is not what it
// claims to be, and reporting it as absent would hide that.
check("truncated: a payload that is not an object is unreadable") {
    let pairs = TurnPairing.pairs(
        from: [event("turn:completed", turn: "a", detail: "[1,2,3]")],
        limit: 5, order: .chronological)
    return pairs.first?.userMessage == .unreadable
}

print(
    failures == 0
        ? "\n✅ all turn history checks passed"
        : "\n❌ \(failures) turn history check(s) failed")
exit(failures == 0 ? 0 : 1)
