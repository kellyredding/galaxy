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
        && DrivenReplyCoding.requests.contains("session.dismiss")
        && DrivenReplyCoding.requests.contains("session.restore")
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

check("input is as strict as the CLI: unknown keys and blank strings are refused") {
    let cases: [(Any?, String)] = [
        (["mesage": "typo", "message": "x"], "input.mesage: unknown key"),
        (["notes": [["quote": "a", "note": "b", "extra": 1]]],
         "input.notes[0].extra: unknown key"),
        (["message": " \n\t"], "input.message must be a non-empty string"),
        (["notes": [["quote": "  ", "note": "b"]]],
         "input.notes[0] needs a non-empty quote and note"),
        (["summary": "   ", "notes": [["quote": "a", "note": "b"]]],
         "input.summary must be a non-empty string"),
        (["notes": ["not an object"]], "input.notes[0] must be an object"),
    ]
    return cases.allSatisfy { raw, message in
        DrivenInput.parse(raw) == .failure(.init(message: message))
    } && DrivenInput.parse(["message": "  keep my spacing  "]) == .success(.message("  keep my spacing  "))
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

// MARK: - Send ids

func parsedSend(_ raw: Any?) -> DrivenSend? {
    if case .success(let send) = DrivenSend.parse(raw) { return send }
    return nil
}

check("a send carries its id apart from its content") {
    guard let send = parsedSend(["id": "lead-7", "message": "do it"]) else { return false }
    return send.inputID == "lead-7" && send.input == .message("do it")
}

check("a send needs an id the CLI would accept") {
    let bad = "input.id must be 1-128 characters of A-Z a-z 0-9 . _ : -"
    let cases: [(Any?, String)] = [
        (["message": "x"], "input.id: missing"),
        (["id": 7, "message": "x"], bad),
        (["id": "", "message": "x"], bad),
        (["id": String(repeating: "a", count: 129), "message": "x"], bad),
        (["id": "has space", "message": "x"], bad),
        (["id": "é", "message": "x"], bad),
    ]
    return cases.allSatisfy { raw, message in
        DrivenSend.parse(raw) == .failure(.init(message: message))
    } && DrivenSend.isValidID("Atlas.lead_2026-11-21:0007")
        && DrivenSend.isValidID(String(repeating: "a", count: 128))
}

check("the content is still checked once the id is taken out") {
    DrivenSend.parse(["id": "x", "message": "  "])
        == .failure(.init(message: "input.message must be a non-empty string"))
        && DrivenSend.parse(["id": "x", "mesage": "typo"])
            == .failure(.init(message: "input.mesage: unknown key"))
}

check("the content hash ignores key order and the id, and tells content apart") {
    let a = parsedSend(["id": "one", "summary": "s", "notes": [["quote": "q", "note": "n"]]])
    let b = parsedSend(["notes": [["note": "n", "quote": "q"]], "summary": "s", "id": "two"])
    let c = parsedSend(["id": "one", "summary": "s", "notes": [["quote": "q", "note": "N"]]])
    guard let a, let b, let c else { return false }
    return a.contentHash == b.contentHash && a.contentHash != c.contentHash
        && a.contentHash.count == 64
}

check("a new id is accepted, a resend is a duplicate, a reused id is a conflict") {
    guard let send = parsedSend(["id": "lead-7", "message": "do it"]),
        let changed = parsedSend(["id": "lead-7", "message": "do something else"])
    else { return false }
    let accepted = [send.inputID: send.contentHash]
    return send.decision(given: [:]) == .accept
        && send.decision(given: accepted) == .duplicate
        && changed.decision(given: accepted) == .conflict
        && send.decision(given: ["other": send.contentHash]) == .accept
}

check("the recorded detail carries the id and hash a resend is checked against") {
    guard let send = parsedSend(["id": "lead-7", "message": "do it"]) else { return false }
    let detail = send.detail(composed: "do it", owner: "Atlas lead")
    let data = try JSONSerialization.data(withJSONObject: detail)
    let recorded = DrivenSend.accepted(fromRecordedDetail: String(data: data, encoding: .utf8))
    return detail["message"] as? String == "do it"
        && recorded?.id == "lead-7" && recorded?.hash == send.contentHash
        && DrivenSend.accepted(fromRecordedDetail: #"{"message":"old"}"#) == nil
        && DrivenSend.accepted(fromRecordedDetail: nil) == nil
}

// MARK: - Watch lines

func watchLine(_ event: String, ref: String?, detail: [String: Any]? = nil) throws -> [String: Any] {
    let data = WatchLine.encode(
        event: event, ref: ref, ts: 1_800_000_000, sessionID: "abc-id", detail: detail)
    guard !data.contains(0x0A) else { throw CocoaError(.coderInvalidValue) }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

check("an event with no row to read carries its detail, and others carry none") {
    let failed = try watchLine("session.input:failed", ref: nil, detail: ["input_id": "lead-7"])
    let plain = try watchLine("timeline.turn:completed", ref: "5")
    return failed["event_id"] is NSNull
        && (failed["detail"] as? [String: String]) == ["input_id": "lead-7"]
        && plain["detail"] == nil
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

// MARK: - Exits

check("an exit someone asked for names who; a crash names nobody") {
    let stopped = DrivenExit.detail(exitCode: 0, initiatedBy: "driver")
    let crashed = DrivenExit.detail(exitCode: 1, initiatedBy: nil)
    return DrivenExit.eventType == "session:exited"
        && stopped["initiated_by"] as? String == "driver"
        && stopped["exit_code"] as? Int == 0
        && crashed["initiated_by"] == nil
        && crashed["exit_code"] as? Int == 1
        && DrivenExit.detail(exitCode: nil, initiatedBy: nil).isEmpty
}

// MARK: - Trusted folders

func trustConfig(_ projects: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["projects": projects, "numStartups": 3])
}

check("a folder Claude Code trusts is trusted") {
    let config = try trustConfig(["/work/repo": ["hasTrustDialogAccepted": true]])
    return ClaudeTrust.decide(directory: "/work/repo", config: config) == .trusted
        && ClaudeTrust.decide(directory: "/work/repo/", config: config) == .trusted
}

check("trust is per folder: a trusted parent does not cover its children") {
    let config = try trustConfig(["/work": ["hasTrustDialogAccepted": true]])
    return ClaudeTrust.decide(directory: "/work/repo", config: config) == .untrusted
}

check("a folder that is listed but not accepted, or not listed, is untrusted") {
    let config = try trustConfig([
        "/work/declined": ["hasTrustDialogAccepted": false],
        "/work/unanswered": ["allowedTools": []],
    ])
    return ClaudeTrust.decide(directory: "/work/declined", config: config) == .untrusted
        && ClaudeTrust.decide(directory: "/work/unanswered", config: config) == .untrusted
        && ClaudeTrust.decide(directory: "/work/absent", config: config) == .untrusted
}

func realPathOf(_ url: URL) -> String? {
    guard let real = realpath(url.path, nil) else { return nil }
    defer { free(real) }
    return String(cString: real)
}

check("a folder trusted under its real path is trusted under a symlink to it") {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("lock-smoke-trust-\(UUID().uuidString)")
    let real = base.appendingPathComponent("real")
    let link = base.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    guard let key = realPathOf(real) else { return false }
    let config = try trustConfig([key: ["hasTrustDialogAccepted": true]])
    return ClaudeTrust.decide(directory: link.path, config: config) == .trusted
}

check("a /private/tmp folder trusted by its real path is trusted however it is spelled") {
    let short = URL(fileURLWithPath: "/tmp/lock-smoke-private-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: short, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: short) }
    guard let key = realPathOf(short), key.hasPrefix("/private/") else { return false }
    let config = try trustConfig([key: ["hasTrustDialogAccepted": true]])
    return ClaudeTrust.decide(directory: short.path, config: config) == .trusted
        && ClaudeTrust.decide(directory: key, config: config) == .trusted
        && ClaudeTrust.decide(directory: key + "/", config: config) == .trusted
}

check("an unreadable config is neither trusted nor reported as untrusted") {
    guard case .unreadable = ClaudeTrust.decide(directory: "/work/repo", config: Data("{".utf8))
    else { return false }
    return ClaudeTrust.refusal(for: "/work/repo", decision: .unreadable("could not parse"))?
        .contains("cannot tell whether Claude Code trusts /work/repo") == true
}

check("the refusal names the folder and what to do, and a trusted folder has none") {
    let refusal = ClaudeTrust.refusal(for: "/work/repo", decision: .untrusted) ?? ""
    return refusal.contains("/work/repo") && refusal.contains("trust it first")
        && ClaudeTrust.refusal(for: "/work/repo", decision: .trusted) == nil
}

// MARK: - Result

if failures == 0 {
    print("\nAll checks passed.")
    exit(0)
} else {
    print("\n\(failures) check(s) failed.")
    exit(1)
}
