import Foundation

// Sandboxed smoke check for driven sessions' model: the lock state, the owner's
// token, the launch arguments that keep an unattended session from ever
// stopping for input, and the wire shapes `galaxy session` reads (replies,
// input, watch lines). Runs as its own process — no app, no Session, no
// SessionManager. Run via `make smoke`. Exits non-zero if any check fails.
//
// What this does NOT check: that a lock actually refuses keystrokes (Galactic's
// tests cover the terminal gate) or that Claude Code honours the arguments,
// which only a real launch can show.

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

let fixedTime = Date(timeIntervalSince1970: 1_800_000_000)
func clock(_ date: Date) -> String { "T\(Int(date.timeIntervalSince(fixedTime)))" }

// MARK: - Tokens

check("a token is 64 hex characters") {
    let token = DrivenToken.generate()
    return token.count == 64 && token.allSatisfy { $0.isHexDigit }
}

check("two tokens differ") {
    DrivenToken.generate() != DrivenToken.generate()
}

check("a token matches itself") {
    let token = DrivenToken.generate()
    return DrivenToken.matches(token, token)
}

check("a token refuses a different one of the same length") {
    !DrivenToken.matches(DrivenToken.generate(), DrivenToken.generate())
}

check("a token refuses its own prefix and an extension of itself") {
    let token = DrivenToken.generate()
    return !DrivenToken.matches(String(token.dropLast()), token)
        && !DrivenToken.matches(token + "0", token)
        && !DrivenToken.matches("", token)
}

// MARK: - Lock state

check("a new owner holds the lock from the start") {
    let state = DrivenState.issue(owner: "Atlas lead", at: fixedTime)
    return state.locked && state.lastLockedAt == fixedTime
        && state.lastReleasedAt == nil && state.lastReleasedBy == nil
}

check("a release records when and by whom, and keeps the last lock time") {
    var state = DrivenState.issue(owner: "Atlas lead", at: fixedTime)
    state.release(by: .user, at: fixedTime.addingTimeInterval(60))
    return !state.locked && state.lastReleasedBy == .user
        && state.lastReleasedAt == fixedTime.addingTimeInterval(60)
        && state.lastLockedAt == fixedTime
}

check("locking again keeps the last release on record") {
    var state = DrivenState.issue(owner: "Atlas lead", at: fixedTime)
    state.release(by: .owner, at: fixedTime.addingTimeInterval(60))
    state.lock(at: fixedTime.addingTimeInterval(120))
    return state.locked && state.lastReleasedBy == .owner
        && state.lastLockedAt == fixedTime.addingTimeInterval(120)
}

check("the state accepts only its own token") {
    let state = DrivenState.issue(owner: "Atlas lead")
    return state.accepts(token: state.token) && !state.accepts(token: "nope")
}

// MARK: - Persistence

/// The shape of a persisted session as far as this field is concerned: an
/// Optional decoded by the synthesised initialiser, as `PersistedSession` is.
struct PersistedFragment: Codable {
    let id: String
    let driven: DrivenState?
}

check("a session written before driven state existed still decodes") {
    let old = #"{"id":"abc"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(PersistedFragment.self, from: old)
    return decoded.id == "abc" && decoded.driven == nil
}

check("driven state survives a round trip") {
    var state = DrivenState.issue(owner: "Atlas lead", at: fixedTime)
    state.release(by: .user, at: fixedTime.addingTimeInterval(5))
    let data = try JSONEncoder().encode(PersistedFragment(id: "x", driven: state))
    let back = try JSONDecoder().decode(PersistedFragment.self, from: data)
    return back.driven == state
}

// MARK: - Tooltip

check("a locked session says since when") {
    DrivenState.issue(owner: "Atlas lead", at: fixedTime).summary(time: clock)
        == "Driven by Atlas lead · locked since T0"
}

check("a force release names the person") {
    var state = DrivenState.issue(owner: "Atlas lead", at: fixedTime)
    state.release(by: .user, at: fixedTime.addingTimeInterval(30))
    return state.summary(time: clock) == "Driven by Atlas lead · released by you at T30"
}

check("an owner's release names nobody") {
    var state = DrivenState.issue(owner: "Atlas lead", at: fixedTime)
    state.release(by: .owner, at: fixedTime.addingTimeInterval(30))
    return state.summary(time: clock) == "Driven by Atlas lead · released at T30"
}

// MARK: - Launch arguments

check("vanilla claude gets one --disallowed-tools with every tool") {
    let args = DrivenLaunch.arguments(persona: false)
    return Array(args.prefix(4))
        == ["--disallowed-tools", "AskUserQuestion", "EnterPlanMode", "ExitPlanMode"]
}

check("claude-persona gets the flag once per tool") {
    let args = DrivenLaunch.arguments(persona: true)
    return Array(args.prefix(6)) == [
        "--disallowed-tools", "AskUserQuestion",
        "--disallowed-tools", "EnterPlanMode",
        "--disallowed-tools", "ExitPlanMode",
    ]
}

check("both shapes end with the inline settings") {
    [true, false].allSatisfy { persona in
        let args = DrivenLaunch.arguments(persona: persona)
        return args.count >= 2 && args[args.count - 2] == "--settings"
            && args.last == DrivenLaunch.settingsJSON
    }
}

check("the inline settings install the always-allow permission hook") {
    let data = DrivenLaunch.settingsJSON.data(using: .utf8)!
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let hooks = object?["hooks"] as? [String: Any]
    let groups = hooks?["PermissionRequest"] as? [[String: Any]]
    let entries = groups?.first?["hooks"] as? [[String: Any]]
    return entries?.first?["type"] as? String == "command"
        && entries?.first?["command"] as? String
            == "~/.claude/galaxy/bin/galaxy-ledger allow-permission"
}

// MARK: - Replies

func decodedReply(_ reply: DrivenReply) throws -> [String: Any] {
    let data = DrivenReplyCoding.encode(reply)
    guard !data.contains(0x0A) else { throw CocoaError(.coderInvalidValue) }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

check("a success reply carries ok and its fields on one line") {
    let object = try decodedReply(.success(["id": "abc", "locked": true]))
    return object["ok"] as? Bool == true && object["id"] as? String == "abc"
        && object["locked"] as? Bool == true
}

check("a refusal carries ok false and the error") {
    let object = try decodedReply(.failure(.init(message: "token does not match")))
    return object["ok"] as? Bool == false
        && object["error"] as? String == "token does not match"
        && object["holder_pid"] == nil
}

check("a refused resume names the holder's pid") {
    let object = try decodedReply(.failure(.init(message: "held by pid 42", holderPid: 42)))
    return object["holder_pid"] as? Int == 42
}

check("null fields survive as JSON null") {
    let object = try decodedReply(.success(["event_id": NSNull(), "pending": true]))
    return object["event_id"] is NSNull && object["pending"] as? Bool == true
}

check("a text field holding a newline still encodes on one line") {
    let object = try decodedReply(.failure(.init(message: "line one\nline two")))
    return object["error"] as? String == "line one\nline two"
}

check("only the CLI's requests are claimed, not session notifications") {
    DrivenReplyCoding.requests.contains("session.send")
        && !DrivenReplyCoding.requests.contains("session.metrics")
        && !DrivenReplyCoding.requests.contains("session.idle")
}

// MARK: - Input

check("a message parses") {
    DrivenInput.parse(["message": "do the thing"]) == .success(.message("do the thing"))
}

check("notes parse with and without a summary") {
    let raw: [String: Any] = ["summary": "overall", "notes": [["quote": "a", "note": "b"]]]
    return DrivenInput.parse(raw)
        == .success(.notes(summary: "overall", notes: [.init(quote: "a", note: "b")]))
        && DrivenInput.parse(["notes": [["quote": "a", "note": "b"]]])
            == .success(.notes(summary: nil, notes: [.init(quote: "a", note: "b")]))
}

check("malformed input is refused with where it went wrong") {
    let cases: [(Any?, String)] = [
        (nil, "input must be an object"),
        (["message": ""], "input.message must be a non-empty string"),
        (["message": "x", "notes": []], "input takes message or notes, not both"),
        (["notes": []], "input needs a message or a non-empty notes array"),
        (["notes": [["quote": "a"]]], "input.notes[0] needs a non-empty quote and note"),
        (["summary": "", "notes": [["quote": "a", "note": "b"]]],
         "input.summary must be a non-empty string"),
    ]
    return cases.allSatisfy { raw, message in
        DrivenInput.parse(raw) == .failure(.init(message: message))
    }
}

check("the recorded detail keeps what galaxy-timeline message prints") {
    let input = DrivenInput.notes(summary: "s", notes: [.init(quote: "q", note: "n")])
    let detail = input.detail(composed: "COMPOSED", owner: "Atlas lead")
    let notes = detail["notes"] as? [[String: String]]
    return detail["message"] as? String == "COMPOSED"
        && detail["owner"] as? String == "Atlas lead"
        && detail["note_count"] as? Int == 1 && detail["summary"] as? String == "s"
        && notes == [["quote": "q", "note": "n"]]
}

check("a message's detail carries no note fields") {
    let detail = DrivenInput.message("hi").detail(composed: "hi", owner: "o")
    return detail["note_count"] == nil && detail["notes"] == nil && detail["summary"] == nil
}

check("pointers name the sender and the read command") {
    let read = "galaxy-timeline message 7"
    return DrivenInput.message("x").pointer(owner: "Atlas lead", readCommand: read)
        == "Atlas lead sent you a message. Read it with `galaxy-timeline message 7`."
        && DrivenInput.notes(summary: nil, notes: [.init(quote: "q", note: "n")])
            .pointer(owner: "Atlas lead", readCommand: read)
            == "Atlas lead sent you 1 note. Read it with `galaxy-timeline message 7`, "
                + "then quote the note before you respond to it."
        && DrivenInput.notes(
            summary: nil, notes: [.init(quote: "q", note: "n"), .init(quote: "r", note: "m")]
        ).pointer(owner: "Atlas lead", readCommand: read)
            == "Atlas lead sent you 2 notes. Read them with `galaxy-timeline message 7`, "
                + "then quote each note before you respond to it."
}

// MARK: - Watch lines

func watchLine(_ event: String, ref: String?) throws -> [String: Any] {
    let data = WatchLine.encode(event: event, ref: ref, ts: 1_800_000_000, sessionID: "abc-id")
    guard !data.contains(0x0A) else { throw CocoaError(.coderInvalidValue) }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

check("a timeline event's line carries its row id and an unprefixed type") {
    let line = try watchLine("timeline.turn:completed", ref: "171809")
    return line["v"] as? Int == 1 && line["event_id"] as? Int == 171809
        && line["type"] as? String == "turn:completed"
        && line["session_id"] as? String == "abc-id"
        && line["occurred_at"] as? String == "2027-01-15T08:00:00Z"
}

check("anything else has a null event id and keeps its name") {
    let line = try watchLine("session.idle", ref: nil)
    return line["event_id"] is NSNull && line["type"] as? String == "session.idle"
}

check("a non-timeline ref is not mistaken for a row id") {
    let line = try watchLine("session:ready", ref: "startup")
    return line["event_id"] is NSNull && line["type"] as? String == "session:ready"
}

check("a subscribe line gives back the id exactly as written") {
    let id = "9b2d8c4e-1111-4a2b-8c3d-000000000001"
    return WatchSubscribeRequest.sessionID(
        from: Data(#"{"v":1,"subscribe":"\#(id)"}"#.utf8)) == id
}

check("anything that is not a subscribe line is refused") {
    [#"{"v":1}"#, #"{"subscribe":"not-a-uuid"}"#, "nonsense"].allSatisfy {
        WatchSubscribeRequest.sessionID(from: Data($0.utf8)) == nil
    }
}

check("a subscriber may fall behind by the capacity and no more") {
    var backpressure = WatchBackpressure()
    let kept = (0..<WatchBackpressure.capacity).allSatisfy { _ in backpressure.sent() }
    return kept && !backpressure.sent()
}

check("delivered lines make room again") {
    var backpressure = WatchBackpressure()
    for _ in 0..<WatchBackpressure.capacity { _ = backpressure.sent() }
    backpressure.delivered()
    return backpressure.sent()
}

// MARK: - Result

if failures == 0 {
    print("\nAll checks passed.")
    exit(0)
} else {
    print("\n\(failures) check(s) failed.")
    exit(1)
}
