# Setup

This guide walks through building and installing the full Galaxy ecosystem
on macOS — the 8 CLI tools plus the Galaxy.app SwiftUI desktop app.

## Prerequisites

- **macOS 14.0** (Sonoma) or later
- **Xcode 16.2+** with Swift 6.0+ — required for building Galaxy.app.
  Install via the App Store, or via
  [developer.apple.com](https://developer.apple.com/download/applications/)
  for older macOS versions. Then point developer tools at it:
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept
  ```
- **XcodeGen** — generates the Xcode project from `project.yml`:
  ```bash
  brew install xcodegen
  ```
- **Crystal toolchain** (`crystal` + `shards`) — required for the CLI
  tools. Recommended via [mise](https://mise.jdx.dev/):
  ```bash
  mise install crystal@latest
  ```
- **Claude Code** installed and authenticated — the ledger CLI's install
  step invokes `claude -p` for eval specs; an unauthenticated session
  aborts the install.

## Clone

```bash
git clone git@github.com:kellyredding/galaxy.git
cd galaxy
```

## 1. Build and install the CLI tools

Each tool lives under `tools/<name>/` with its own Makefile. The per-tool
`install` target builds the tool, runs its `check` target (lint + tests),
and copies the binary into `~/.claude/galaxy/bin/` along with a symlink at
`~/.bin/local/<name>`.

```bash
make statusline-install
make ledger-install
make snapshots-install
make artifacts-install
make timeline-install
make agents-install
make diff-install
make galaxy-install
```

Or build a single tool from its own directory:

```bash
cd tools/statusline
make install
```

**Where things land:**

- Binaries: `~/.claude/galaxy/bin/<name>`
- PATH symlinks: `~/.bin/local/<name>`

Add `~/.bin/local/` to your `PATH` if it isn't already.

## 2. Build the Mac app (Galaxy.app)

```bash
cd GalaxyApp
xcodegen generate
xcodebuild \
    -project GalaxyApp.xcodeproj \
    -scheme GalaxyApp \
    -configuration Debug \
    build
```

The first build resolves SwiftPM dependencies (Galactic and Markdown);
subsequent builds reuse the SwiftPM cache.

For Mac-app-specific details (dependency pinning, SwiftPM cache recovery,
project structure), see [`GalaxyApp/SETUP.md`](GalaxyApp/SETUP.md).

The built app lands at:

```
GalaxyApp/build/Build/Products/Debug/Galaxy.app
```

Open it once to grant the usual macOS first-run permissions:

```bash
open GalaxyApp/build/Build/Products/Debug/Galaxy.app
```

Optionally symlink it into `~/Applications/` so Launch Services
(Spotlight, Raycast, Cmd-Tab) can find it:

```bash
mkdir -p ~/Applications
ln -sfn "$PWD/GalaxyApp/build/Build/Products/Debug/Galaxy.app" \
    ~/Applications/Galaxy.app
```

## Verify

```bash
galaxy --version
galaxy-statusline --version
# ... and the rest of the CLIs

open ~/Applications/Galaxy.app   # or the build path directly
```
