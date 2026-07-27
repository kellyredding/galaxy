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

    /// How a binding is spelled for a person. Swift renders this in the
    /// settings card, the JavaScript module in the composer placeholder.
    struct Label: Decodable {
        let keyCode: UInt16
        let code: String
        let modifiers: Int
        let label: String
    }

    let labels: [Label]
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
    // 10 is kVK_ISO_Section — a real key, absent from the table, and therefore
    // one the recorder refuses rather than binding to nothing.
    Keystroke(keyCode: 10).domCode == nil
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

check("the default follows Claude Code: Return commits, Option-Return does not") {
    let bindings = TextEntryBindings.default
    let bare = Keystroke(keyCode: Keystroke.Key.ret)
    let option = Keystroke(keyCode: Keystroke.Key.ret, modifiers: .option)
    let command = Keystroke(keyCode: Keystroke.Key.ret, modifiers: .command)
    return bindings.action(for: bare) == .submit
        && bindings.action(for: option) == .newline
        && bindings.action(for: command) == nil
}

check("the shipped default is the one the JavaScript side verifies") {
    // Pins TextEntryBindings.default to the fixture's own default scenario,
    // which the JavaScript verifier runs against its own DEFAULT_BINDINGS.
    // Without this, the two defaults could drift apart and every other check
    // would still pass.
    guard let scenario = fixture.scenarios.first(where: {
        $0.name == "shipped defaults"
    }) else { return false }
    return scenario.bindings == TextEntryBindings.default
}

// MARK: - Labels, the reserved chord, and empty-list coercion

check("every binding is spelled the way the fixture says") {
    for entry in fixture.labels {
        let keystroke = Keystroke(
            keyCode: entry.keyCode,
            modifiers: Keystroke.Modifiers(rawValue: entry.modifiers)
        )
        if keystroke.displayLabel != entry.label { return false }
    }
    return true
}

check("every key in the table has both a label and a DOM code") {
    for (code, info) in Keystroke.keyTable {
        if info.label.isEmpty || info.domCode.isEmpty { return false }
        let keystroke = Keystroke(keyCode: code)
        // A key that renders as "Key 38" is one the table forgot.
        if keystroke.displayLabel.hasPrefix("Key ") { return false }
        if keystroke.domCode == nil { return false }
    }
    return true
}

check("no two keys share a DOM code") {
    let codes = Keystroke.keyTable.values.map(\.domCode)
    return Set(codes).count == codes.count
}

check("Ctrl+J survives the payload rather than being dropped") {
    // Regression: J had a label but no DOM code, so jsPayload's compactMap
    // dropped this binding. It looked bound in the settings card, did nothing
    // in every composer, and beeped because the unhandled event fell through
    // to WebKit's editing machinery.
    let ctrlJ = Keystroke(keyCode: 38, modifiers: .control)
    let bindings = TextEntryBindings(submit: [], newline: [ctrlJ])
    guard let newline = bindings.jsPayload["newline"], newline.count == 1
    else { return false }
    return ctrlJ.displayLabel == "⌃J"
        && ctrlJ.domCode == "KeyJ"
        && newline[0]["code"] as? String == "KeyJ"
        && newline[0]["modifiers"] as? Int == 4
}

check("a key outside the table is not bindable") {
    // ISO section key — real, but absent from the table, so it must not be
    // offered as a binding that silently cannot reach a composer.
    Keystroke(keyCode: 10).isBindable == false
        && Keystroke(keyCode: 38).isBindable
}

check("the reserved chord is all four modifiers plus Return") {
    let reserved = Keystroke.reservedMachineSubmit
    return reserved.keyCode == Keystroke.Key.ret
        && reserved.modifiers == [.control, .option, .shift, .command]
        && reserved.displayLabel == "⌃⌥⇧⌘Enter"
}

check("the reserved chord is not one of the shipped defaults") {
    // If it were, the recorder would refuse a keystroke the app itself ships.
    let bindings = TextEntryBindings.default
    return !bindings.submit.contains(Keystroke.reservedMachineSubmit)
        && !bindings.newline.contains(Keystroke.reservedMachineSubmit)
}

check("an empty list decodes back to its default") {
    let emptied = TextEntryBindings(submit: [], newline: [])
    return emptied.coercingEmptyLists() == TextEntryBindings.default
}

check("coercion leaves a populated list alone") {
    let custom = TextEntryBindings(
        submit: [Keystroke(keyCode: Keystroke.Key.ret, modifiers: .control)],
        newline: [Keystroke(keyCode: Keystroke.Key.ret, modifiers: .shift)]
    )
    return custom.coercingEmptyLists() == custom
}

check("coercion fixes only the empty side") {
    let halfEmpty = TextEntryBindings(
        submit: [],
        newline: [Keystroke(keyCode: Keystroke.Key.ret, modifiers: .shift)]
    )
    let fixed = halfEmpty.coercingEmptyLists()
    return fixed.submit == TextEntryBindings.default.submit
        && fixed.newline == halfEmpty.newline
}

// MARK: - The payload handed to the WebView matcher

check("the JS payload keys keystrokes by DOM code, not virtual key code") {
    let payload = TextEntryBindings.default.jsPayload
    guard let submit = payload["submit"], submit.count == 1,
          let newline = payload["newline"], newline.count == 1
    else { return false }
    return submit[0]["code"] as? String == "Enter"
        && submit[0]["modifiers"] as? Int == 0
        && newline[0]["code"] as? String == "Enter"
        && newline[0]["modifiers"] as? Int == 2
}

check("the JS payload drops keystrokes a WebView cannot address") {
    // 10 is kVK_ISO_Section — a real key absent from the table. Passing it
    // along would let a binding look configured while doing nothing, which is
    // how Ctrl+J came to beep instead of inserting a newline.
    let bindings = TextEntryBindings(
        submit: [
            Keystroke(keyCode: 10, modifiers: .command),
            Keystroke(keyCode: Keystroke.Key.ret, modifiers: .command),
        ],
        newline: [Keystroke(keyCode: 10)]
    )
    let payload = bindings.jsPayload
    return payload["submit"]?.count == 1
        && payload["submit"]?[0]["code"] as? String == "Enter"
        && payload["newline"]?.count == 0
}

check("the JS payload survives JSONSerialization") {
    // Both injection paths serialise it; a bad value type would fail only at
    // runtime, in a WebView, with no composer bindings and no error.
    JSONSerialization.isValidJSONObject(TextEntryBindings.default.jsPayload)
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
