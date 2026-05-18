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
xcodebuild -project GalaxyApp.xcodeproj -scheme GalaxyApp -configuration Debug build
```

No pre-step is needed for dependencies — SwiftPM handles SwiftTerm and
Markdown automatically when Xcode opens the generated project or `xcodebuild`
runs.

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

### SwiftPM resolution fails with "revision X does not match previously recorded value Z"

A `v<n>-galactic.<rev>` tag was force-moved on the fork, violating the
immutability rule in the fork's MAINTAINING.md. Recover by wiping the SwiftPM
cache:

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/GalaxyApp-*
rm -rf ~/Library/Caches/org.swift.swiftpm
xcodegen generate
```

### Build succeeds but app crashes

Check Console.app for crash logs. Common issues:

- Claude binary not found (check `~/.local/bin/claude` exists)
- Missing entitlements for terminal access
