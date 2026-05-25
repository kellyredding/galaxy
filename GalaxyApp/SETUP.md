# GalaxyApp Setup Guide

This document explains how to set up the GalaxyApp project for building.

## Prerequisites

- **Xcode 16.2+** (with Swift 6.0+)
- **XcodeGen** (`brew install xcodegen`)
- **Git**

## Quick Start

```bash
cd GalaxyApp

# 1. Generate Xcode project (resolves SPM dependencies on first build)
xcodegen generate

# 2. Build
make build
```

No pre-step is needed for dependencies — SwiftPM handles Galactic and
Markdown automatically when Xcode opens the generated project or
`make build` runs.

The Makefile wraps `xcodebuild` with `-derivedDataPath build`, so all
build state — including the SwiftPM workspace — lives inside the
project-local `build/` directory rather than `~/Library/Developer/
Xcode/DerivedData`. Repo convention is to always build via the
Makefile.

## Swift Package Dependencies

GalaxyApp consumes two SPM packages, declared in `project.yml`:

| Package    | Source                                              | Pin                     |
|------------|-----------------------------------------------------|-------------------------|
| Galactic   | https://github.com/kellyredding/Galactic.git        | `exactVersion: 0.1.0`   |
| Markdown   | https://github.com/swiftlang/swift-markdown.git     | `from: 0.5.0`           |

Galactic is the terminal engine bridge — `TerminalBackend`,
`ScrollbackSnapshot`, the color theme value types, and the rest of
the chrome-engine seam. It also owns a downstream pin on a SwiftTerm
fork (`kellyredding/SwiftTerm`), which arrives as a transitive
dependency. From GalaxyApp's perspective the SwiftTerm fork is an
implementation detail of Galactic — chrome code imports `Galactic`,
not `SwiftTerm`.

The fork rationale, patch table, and bump workflow live in
[Galactic's MAINTAINING.md](https://github.com/kellyredding/Galactic/blob/main/MAINTAINING.md).

### Updating Galactic

To pull a newer Galactic version into GalaxyApp:

1. Confirm the target Galactic release exists on
   [kellyredding/Galactic](https://github.com/kellyredding/Galactic/releases).
2. Update `project.yml`'s Galactic pin (`exactVersion: <new-tag>`).
3. `xcodegen generate && make build`.
4. Smoke-test running Galaxy.app.

If the Galactic bump rolls in a new SwiftTerm fork pin under the hood
(typically the case for a Galactic patch release), exercise the
auto-follow + rendering surface during smoke test — that's where
fork-side regressions surface.

## Project Structure

```
GalaxyApp/
├── scripts/
│   └── generate-emoji-data.py    # Emoji data generation (unrelated to deps)
├── GalaxyApp/                    # Swift source files
├── project.yml                   # XcodeGen project spec
├── SETUP.md                      # This file
└── GalaxyApp.xcodeproj/          # Generated (don't edit directly)
```

## Troubleshooting

### "No such module 'Galactic'"

The Xcode project needs regeneration:

```bash
xcodegen generate
```

If that doesn't resolve it, the SwiftPM workspace under
`build/` may be stale — see the next entry.

### SwiftPM resolution fails to find the Galactic package

Wipe the project-local SPM state and regenerate. The Makefile builds
into `build/` via `-derivedDataPath`, so the workspace state lives
there (not in `~/Library/Developer/Xcode/DerivedData`):

```bash
rm -rf build GalaxyApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
xcodegen generate
make build
```

### `Revision X does not match previously recorded value Y`

SwiftPM caches `(repo URL, version) → revision` globally and rejects
a resolve that returns a different revision for the same version.
This happens if a tag was retargeted to a new commit, or if local
SPM state predates the current tag. Galactic and its upstream
SwiftTerm fork both forbid re-pointing published tags for this exact
reason — but if you hit the error, clear the global SwiftPM cache
plus the project-local state and rebuild:

```bash
rm -rf ~/Library/Caches/org.swift.swiftpm
rm -rf build GalaxyApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
xcodegen generate
make build
```

### Build succeeds but app crashes

Check Console.app for crash logs. Common issues:

- Claude binary not found (check `~/.local/bin/claude` exists)
- Missing entitlements for terminal access
