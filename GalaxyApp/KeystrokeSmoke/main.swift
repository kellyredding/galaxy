import Foundation

// Sandboxed smoke check for the text-entry keystroke model. Runs as its own
// process — no app, no AppKit, no WebView — which is why Keystroke.swift and
// TextEntryBindings.swift are Foundation-only. Run via `make smoke`.
// Exits non-zero if any check fails.
//
// The scenario checks read fixtures/text-entry-cases.json, the same table
// scripts/verify-text-entry.mjs reads. Both sides must agree on every case.

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

// MARK: - The shared fixture table

struct Fixture: Decodable {
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let name: String
        let bindings: TextEntryBindings
        let cases: [Case]
    }

    /// Each case carries both spellings of one physical key: `keyCode` for this
    /// side, `code` for the JavaScript side. Only `keyCode` drives the match
    /// here; `code` is asserted against `Keystroke.domCode` so the pairing the
    /// JavaScript twin relies on cannot drift.
    struct Case: Decodable {
        let name: String
        let keyCode: UInt16
        let code: String
        let modifiers: Int
        let expect: String?
    }
}

let fixturePath =
    CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "fixtures/text-entry-cases.json"

let fixture: Fixture
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
    fixture = try JSONDecoder().decode(Fixture.self, from: data)
} catch {
    print("FAIL  could not load fixture at \(fixturePath) — \(error)")
    exit(1)
}

// MARK: - Scenario checks (shared with the JavaScript verifier)

for scenario in fixture.scenarios {
    for testCase in scenario.cases {
        check("\(scenario.name): \(testCase.name)") {
            let keystroke = Keystroke(
                keyCode: testCase.keyCode,
                modifiers: Keystroke.Modifiers(rawValue: testCase.modifiers)
            )
            let resolved = scenario.bindings.action(for: keystroke)
            return resolved?.rawValue == testCase.expect
        }
    }
}

// MARK: - The key-spelling pairing the JavaScript side depends on

check("every fixture key pairs its virtual key code with the right DOM code") {
    for scenario in fixture.scenarios {
        for testCase in scenario.cases {
            let keystroke = Keystroke(keyCode: testCase.keyCode)
            if keystroke.domCode != testCase.code { return false }
        }
    }
    return true
}

check("Return and keypad Enter map to distinct DOM codes") {
    let ret = Keystroke(keyCode: Keystroke.Key.ret)
    let keypad = Keystroke(keyCode: Keystroke.Key.keypadEnter)
    return ret.domCode == "Enter"
        && keypad.domCode == "NumpadEnter"
        && ret.domCode != keypad.domCode
}

check("a key with no WebView spelling reports nil rather than guessing") {
    // 0 is a real virtual key code (kVK_ANSI_A) that this feature never binds.
    Keystroke(keyCode: 0).domCode == nil
}

// MARK: - Coding

check("bindings round-trip through JSON unchanged") {
    let encoded = try JSONEncoder().encode(TextEntryBindings.default)
    let decoded = try JSONDecoder().decode(
        TextEntryBindings.self, from: encoded)
    return decoded == TextEntryBindings.default
}

check("modifiers encode as a bare integer, not a nested object") {
    // The JavaScript twin and the settings file share this wire format; a
    // nested {"rawValue": n} would break the shared fixture table.
    let encoded = try JSONEncoder().encode(
        Keystroke(keyCode: Keystroke.Key.ret, modifiers: [.command, .shift]))
    let json =
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    return json["modifiers"] as? Int == 9
}

check("the default reproduces today's composer behaviour") {
    let bindings = TextEntryBindings.default
    let bare = Keystroke(keyCode: Keystroke.Key.ret)
    let command = Keystroke(
        keyCode: Keystroke.Key.ret, modifiers: .command)
    return bindings.action(for: bare) == .newline
        && bindings.action(for: command) == .submit
}

// MARK: - Modifier normalisation
//
// This is what `Modifiers.init(deviceFlags:)` exists for, and the reason the
// AppKit bridge is now a one-liner: incidental modifier state must never
// decide whether a binding matches.

check("caps-lock does not defeat a match") {
    Keystroke.Modifiers(
        deviceFlags: Keystroke.Modifiers.DeviceFlag.capsLock
            | Keystroke.Modifiers.DeviceFlag.command
    ) == .command
}

check("the numeric-pad flag does not defeat a match") {
    Keystroke.Modifiers(
        deviceFlags: Keystroke.Modifiers.DeviceFlag.numericPad
            | Keystroke.Modifiers.DeviceFlag.command
    ) == .command
}

check("the fn flag does not defeat a match") {
    Keystroke.Modifiers(
        deviceFlags: Keystroke.Modifiers.DeviceFlag.function
            | Keystroke.Modifiers.DeviceFlag.shift
    ) == .shift
}

check("caps-lock alone normalises to no modifiers") {
    Keystroke.Modifiers(
        deviceFlags: Keystroke.Modifiers.DeviceFlag.capsLock) == []
}

check("all four nameable modifiers survive normalisation") {
    Keystroke.Modifiers(
        deviceFlags: Keystroke.Modifiers.DeviceFlag.command
            | Keystroke.Modifiers.DeviceFlag.option
            | Keystroke.Modifiers.DeviceFlag.control
            | Keystroke.Modifiers.DeviceFlag.shift
    ) == [.command, .option, .control, .shift]
}

check("each nameable modifier maps to its own bit") {
    let flags = Keystroke.Modifiers.DeviceFlag.self
    return Keystroke.Modifiers(deviceFlags: flags.command) == .command
        && Keystroke.Modifiers(deviceFlags: flags.option) == .option
        && Keystroke.Modifiers(deviceFlags: flags.control) == .control
        && Keystroke.Modifiers(deviceFlags: flags.shift) == .shift
}

// MARK: - Result

if failures == 0 {
    print("\n✅ all keystroke smoke checks passed")
    exit(0)
}
print("\n❌ \(failures) keystroke smoke check(s) failed")
exit(1)
