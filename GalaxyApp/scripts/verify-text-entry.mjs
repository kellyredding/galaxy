#!/usr/bin/env node
// verify-text-entry.mjs — run the shipped JavaScript matcher against the same
// fixture table the Swift smoke target uses.
//
// This is a behaviour gate, not a syntax gate. validate-js.mjs proves the
// embedded literal parses; this proves it *agrees with Swift*. Two matchers
// implementing one rule in two languages will drift, and the drift is silent:
// a chord that stops working inside a WebView composer looks like a WebView
// quirk, not like a mismatched bitmask.
//
// It evaluates the real literal out of Views/TextEntryJS.swift rather than a
// copy, so what runs here is what ships. `window` is a bare object — the
// matcher touches no DOM beyond the event fields it reads, and `bind` is not
// exercised (that needs a real textarea, and stage 2 wires it).

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import { extractMarkedLiterals } from "./lib/swift-literals.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const APP_ROOT = join(SCRIPT_DIR, ".."); // .../GalaxyApp
const LITERAL_FILE = join(APP_ROOT, "GalaxyApp/Views/TextEntryJS.swift");
const LITERAL_NAME = "textEntryJS";
const FIXTURE = join(APP_ROOT, "fixtures/text-entry-cases.json");

// Must match Keystroke.Modifiers on the Swift side, and the bitmask the
// fixture table documents.
const MOD_COMMAND = 1;
const MOD_OPTION = 2;
const MOD_CONTROL = 4;
const MOD_SHIFT = 8;

let failures = 0;

function check(name, body) {
  let ok = false;
  try {
    ok = body();
  } catch (err) {
    console.log(`FAIL  ${name} — threw: ${err.message}`);
    failures++;
    return;
  }
  if (ok) {
    console.log(`PASS  ${name}`);
  } else {
    console.log(`FAIL  ${name}`);
    failures++;
  }
}

// --- Load the shipped literal ----------------------------------------

function loadMatcher() {
  const literals = extractMarkedLiterals(readFileSync(LITERAL_FILE, "utf8"));
  const found = literals.find((l) => l.name === LITERAL_NAME);

  if (!found) {
    throw new Error(
      `no marked literal named ${LITERAL_NAME} in ${LITERAL_FILE}`,
    );
  }
  if (found.error) {
    throw new Error(`${LITERAL_NAME}: ${found.error}`);
  }

  const sandbox = { window: {} };
  vm.createContext(sandbox);
  new vm.Script(found.js, { filename: `${LITERAL_NAME}` }).runInContext(
    sandbox,
  );

  if (!sandbox.window.GalaxyTextEntry) {
    throw new Error(`${LITERAL_NAME} did not define window.GalaxyTextEntry`);
  }
  return sandbox.window.GalaxyTextEntry;
}

/// A keydown event as the matcher sees it, built from the fixture's bitmask.
function eventFor(testCase) {
  return {
    code: testCase.code,
    metaKey: (testCase.modifiers & MOD_COMMAND) !== 0,
    altKey: (testCase.modifiers & MOD_OPTION) !== 0,
    ctrlKey: (testCase.modifiers & MOD_CONTROL) !== 0,
    shiftKey: (testCase.modifiers & MOD_SHIFT) !== 0,
  };
}

// --- Run --------------------------------------------------------------

let matcher;
try {
  matcher = loadMatcher();
} catch (err) {
  console.error(`\n✗ could not load the matcher — ${err.message}\n`);
  process.exit(1);
}

const fixture = JSON.parse(readFileSync(FIXTURE, "utf8"));

for (const scenario of fixture.scenarios) {
  matcher.configure(scenario.bindings);
  for (const testCase of scenario.cases) {
    check(`${scenario.name}: ${testCase.name}`, () => {
      const resolved = matcher.actionFor(eventFor(testCase));
      // The matcher returns null for "not ours"; the fixture spells that as
      // JSON null, which parses to null too.
      return resolved === testCase.expect;
    });
  }
}

// Reconfiguring must replace the previous bindings outright rather than
// merging into them, or a settings change would leave stale bindings live.
check("configure replaces the previous bindings", () => {
  matcher.configure({
    submit: [{ code: "Enter", modifiers: MOD_COMMAND }],
    newline: [],
  });
  matcher.configure({ submit: [], newline: [] });
  return matcher.actionFor(eventFor({ code: "Enter", modifiers: MOD_COMMAND }))
    === null;
});

check("configure tolerates a missing or partial configuration", () => {
  matcher.configure(undefined);
  if (matcher.actionFor(eventFor({ code: "Enter", modifiers: 0 })) !== null) {
    return false;
  }
  matcher.configure({ newline: [{ code: "Enter", modifiers: 0 }] });
  return matcher.actionFor(eventFor({ code: "Enter", modifiers: 0 }))
    === "newline";
});

check("caps-lock is not a modifier the matcher reads", () => {
  matcher.configure({
    submit: [],
    newline: [{ code: "Enter", modifiers: 0 }],
  });
  // getModifierState('CapsLock') would report it; the matcher never asks.
  const event = eventFor({ code: "Enter", modifiers: 0 });
  event.getModifierState = () => true;
  return matcher.actionFor(event) === "newline";
});

if (failures === 0) {
  const total = fixture.scenarios.reduce((n, s) => n + s.cases.length, 0);
  console.log(
    `\n✅ text-entry JS matches Swift — ${total} shared case(s) ` +
      `across ${fixture.scenarios.length} scenario(s)`,
  );
  process.exit(0);
}
console.error(`\n❌ ${failures} text-entry check(s) failed`);
process.exit(1);
