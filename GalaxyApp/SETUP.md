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

No pre-step is needed for dependencies — SwiftPM handles SwiftTerm and
Markdown automatically when Xcode opens the generated project or
`make build` runs.

The Makefile wraps `xcodebuild` with `-derivedDataPath build`, so all
build state — including the SwiftPM workspace — lives inside the
project-local `build/` directory rather than `~/Library/Developer/
Xcode/DerivedData`. Repo convention is to always build via the
Makefile.

## Swift Package Dependencies

GalaxyApp consumes two SPM packages, declared in `project.yml`:

| Package    | Source                                              | Pin                              |
|------------|-----------------------------------------------------|----------------------------------|
| SwiftTerm  | https://github.com/kellyredding/SwiftTerm.git       | `exactVersion: 1.13.0-galactic.4`|
| Markdown   | https://github.com/swiftlang/swift-markdown.git     | `from: 0.5.0`                    |

### SwiftTerm — the Galactic fork

`kellyredding/SwiftTerm` is a personal fork of
[migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) carrying
Galactic-specific customization patches on top of upstream tagged releases.
The fork publishes immutable `v<upstream>-galactic.<rev>` tags so SwiftPM's
cache stays consistent across consumers.

The bump workflow (adopting a newer upstream SwiftTerm or re-cutting a patch
revision) is documented in the fork's own `MAINTAINING.md`. From GalaxyApp's
perspective, a bump is a one-line `exactVersion:` update in `project.yml`
followed by `xcodegen generate` to refresh the Xcode project's resolved
dependency graph.

A branch pin (`branch: bump/v<target>`) can be used in `project.yml`
temporarily while iterating on fork-side changes during a bump — but
the default consumer state is an `exactVersion:` tag pin, which gives
SwiftPM a deterministic resolution every consumer can share.

#### Why a fork at all?

A small set of patches lives on top of upstream that we need for the
Galactic rendering surface:

| Patch                            | Purpose                                                                |
|----------------------------------|------------------------------------------------------------------------|
| `galacticBoldForegroundColor`    | Per-theme bold-text foreground override                                |
| Auto-follow rendering invariants | Keep scrollback pinned to live output unless user has scrolled up      |
| `makeBackingLayer` visibility    | Allow Galaxy's cross-module override                                   |
| Pixel-snap skip, FillStroke tune | Visual parity with the scrollback overlay's WebKit rendering           |

These live as a permanent customization commit on top of each upstream
version bump in the fork. See the fork's `MAINTAINING.md` and
`PATCHES.md` for the full rationale, the per-release patch log, and
the bump workflow.

### Updating SwiftTerm

To pull a newer SwiftTerm version into GalaxyApp:

1. Bump the fork (see the fork's `MAINTAINING.md` — produces a tag
   like `v<upstream>-galactic.<rev>`).
2. Update `project.yml`'s SwiftTerm pin to the new tag.
3. `xcodegen generate && make build`.
4. Smoke-test running Galaxy.app.

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

### "No such module 'SwiftTerm'"

The Xcode project needs regeneration:

```bash
xcodegen generate
```

### SwiftPM resolution fails to find the SwiftTerm package

Wipe the project-local SPM state and regenerate. The Makefile builds
into `build/` via `-derivedDataPath`, so the workspace state lives
there (not in `~/Library/Developer/Xcode/DerivedData`):

```bash
rm -rf build GalaxyApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
xcodegen generate
make build
```

### `Revision X does not match previously recorded value Y`

SwiftPM caches `(repo URL, version) → revision` globally and rejects a
resolve that returns a different revision for the same version. This
happens if a fork tag was retargeted to a new commit, or if local SPM
state predates the current tag. The fork's `MAINTAINING.md` forbids
re-pointing published tags for this exact reason — but if you hit the
error, clear the global SwiftPM cache plus the project-local state and
rebuild:

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
