import Foundation

// Sandboxed smoke check for the sessions panel's visibility rule. Runs as its
// own process — no app, no window, no SettingsManager. Run via `make smoke`.
// Exits non-zero if any check fails.
//
// It exists because the rule has three inputs and one output, and the
// interesting cases are the ones where two of the inputs disagree. Those are
// unreachable from the app without opening a diff, moving the panel by hand and
// navigating away in each of several orders — which is how the same rule would
// come to be implemented twice and asserted never.
//
// What is asserted here: that a condition never spends the reader's choice,
// that two surfaces cannot cancel one another, and that a reader who overrules
// a held panel keeps what they asked for on the way out.
//
// What this does NOT check, stated plainly: anything with a pixel or a clock in
// it. The restore settle, the display throttle, the opacity swap and the column
// width all live in `SidebarPreferences` and `ContentView`, and are only
// verifiable by using the app.

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

/// A panel at rest, showing or not. Named so a check states only the fact it is
/// about.
func panel(showing: Bool) -> SessionsPanelModel {
    SessionsPanelModel(preferred: showing)
}

// MARK: - Resting state

check("resting: a chosen panel shows") {
    panel(showing: true).isVisible
}

check("resting: a dismissed panel stays dismissed") {
    !panel(showing: false).isVisible
}

// MARK: - One condition

check("a condition takes a showing panel") {
    var m = panel(showing: true)
    m.set(true, condition: .diffReader)
    return !m.isVisible
}

check("a condition changes nothing when the panel was already shut") {
    var m = panel(showing: false)
    m.set(true, condition: .diffReader)
    return !m.isVisible
}

check("retracting the only condition gives a showing panel back") {
    var m = panel(showing: true)
    m.set(true, condition: .diffReader)
    m.set(false, condition: .diffReader)
    return m.isVisible
}

check("retracting the only condition leaves a shut panel shut") {
    var m = panel(showing: false)
    m.set(true, condition: .diffReader)
    m.set(false, condition: .diffReader)
    return !m.isVisible
}

check("asserting the same condition twice is one assertion") {
    var m = panel(showing: true)
    m.set(true, condition: .diffReader)
    m.set(true, condition: .diffReader)
    m.set(false, condition: .diffReader)
    return m.isVisible
}

check("retracting a condition that was never asserted is harmless") {
    var m = panel(showing: true)
    m.set(false, condition: .diffReader)
    return m.isVisible
}

// MARK: - The reader disagreeing
//
// The three situations the re-capture rule was chosen for. Each is a keystroke
// the reader would otherwise find dead or, worse, silently undone on the way
// out.

check("the reader can take a held panel back") {
    var m = panel(showing: true)
    m.set(true, condition: .diffReader)
    m.setPreferred(true)
    return m.isVisible
}

check("hiding an already-held panel is recorded, not swallowed") {
    var m = panel(showing: true)
    m.set(true, condition: .diffReader)
    m.setPreferred(false)                   // no visible change at the time
    m.set(false, condition: .diffReader)
    return !m.isVisible                     // and it does not come back
}

check("showing a held panel survives leaving the surface") {
    var m = panel(showing: false)
    m.set(true, condition: .diffReader)
    m.setPreferred(true)
    m.set(false, condition: .diffReader)
    return m.isVisible
}

check("a condition arriving after the reader overruled does not re-take") {
    var m = panel(showing: true)
    m.set(true, condition: .diffReader)
    m.setPreferred(true)
    m.set(true, condition: .diffReader)
    return m.isVisible
}

check("a fresh visit does take the panel again") {
    var m = panel(showing: true)
    m.set(true, condition: .diffReader)
    m.setPreferred(true)
    m.set(false, condition: .diffReader)    // left the surface
    m.set(true, condition: .diffReader)     // and came back
    return !m.isVisible
}

// MARK: - Mechanism
//
// There are two conditions now, and these are the assertions that could not be
// written while there was one. Both were unreachable rather than untested: the
// branches they exercise exist in `SessionsPanelModel` and no arrangement of a
// single case could reach them, so the file claimed coverage in its header that
// it did not have.

check("two distinct holders do not cancel one another") {
    var m = panel(showing: true)
    m.set(true, condition: .diffReader)
    m.set(true, condition: .filesTab)
    // One lets go. The panel is still held, because the other has not.
    m.set(false, condition: .diffReader)
    return !m.isVisible && m.conditions == [.filesTab]
}

check("a second condition arriving while one is held still accounts") {
    var m = panel(showing: true)
    m.set(true, condition: .diffReader)
    // Arrives with the set already non-empty, which is the branch a single
    // case can never reach: it joins rather than overruling, so its own
    // retraction is still owed.
    m.set(true, condition: .filesTab)
    m.set(false, condition: .filesTab)
    let heldByTheFirst = !m.isVisible && m.conditions == [.diffReader]
    m.set(false, condition: .diffReader)
    return heldByTheFirst && m.isVisible && m.conditions.isEmpty
}

check("a retraction only releases when the last condition goes") {
    var m = panel(showing: true)
    m.set(true, condition: .diffReader)
    // The same condition twice, which is the idempotence the set is for: two
    // asserts and one retract must still leave the panel free, not held by a
    // phantom second holder.
    m.set(true, condition: .diffReader)
    m.set(false, condition: .diffReader)
    return m.isVisible && m.conditions.isEmpty
}

check("clearing every condition restores the choice") {
    var m = panel(showing: true)
    m.set(true, condition: .diffReader)
    m.clearConditions()
    return m.isVisible && !m.isOverruling
}

check("clearing every condition respects a dismissed panel") {
    var m = panel(showing: false)
    m.set(true, condition: .diffReader)
    m.clearConditions()
    return !m.isVisible
}

check("every condition carries words") {
    SessionsPanelCollapseCondition.allCases.allSatisfy {
        !$0.reason.isEmpty
    }
}

// MARK: - Result

if failures == 0 {
    print("\nAll checks passed.")
    exit(0)
} else {
    print("\n\(failures) check(s) failed.")
    exit(1)
}
