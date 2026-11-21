import Foundation

// Sandboxed smoke check for driven sessions' model: the lock state, the owner's
// token, and the launch arguments that keep an unattended session from ever
// stopping for input. Runs as its own process — no app, no Session, no
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

// MARK: - Result

if failures == 0 {
    print("\nAll checks passed.")
    exit(0)
} else {
    print("\n\(failures) check(s) failed.")
    exit(1)
}
