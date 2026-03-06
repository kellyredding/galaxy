# Galaxy

**Galaxy brain for Claude Code** — Multi-agent orchestration tools and a native macOS terminal app for Claude Code.

## Components

| Component | Description | Language |
|-----------|-------------|----------|
| [GalaxyApp](GalaxyApp/) | Native macOS terminal app for Claude Code sessions | Swift |
| [galaxy](tools/galaxy/) | Core CLI tool | Crystal |
| [ledger](tools/ledger/) | Persistent context ledger — captures decisions, learnings, and session files across context resets | Crystal |
| [statusline](tools/statusline/) | Customizable status line with context usage, git status, and more | Crystal |

## Prerequisites

- [Crystal](https://crystal-lang.org/) >= 1.0.0
- [Xcode](https://developer.apple.com/xcode/) 16.2+ with Swift 6.0+ (for GalaxyApp)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) (for GalaxyApp)
- Git

## Quick Install

```bash
# Clone
git clone https://github.com/kellyredding/galaxy.git
cd galaxy

# Install all CLI tools (builds, runs tests, installs binaries + hooks/skills)
make statusline-install
make ledger-install

# Build and install GalaxyApp
cd GalaxyApp
./scripts/setup-vendor.sh   # Clone and patch vendored SwiftTerm
xcodegen generate            # Generate Xcode project
cd ..
make app-build               # Build the app (Debug)

# Copy to ~/Applications (or /Applications)
cp -R GalaxyApp/build/Build/Products/Debug/Galaxy.app ~/Applications/
```

### What `make install` does for each tool

Each tool's `make install` target:

1. Builds a release binary to `tools/<tool>/build/`
2. Installs the binary to `~/.claude/galaxy/bin/`
3. Symlinks the binary into `~/.local/bin/` (add this to your `PATH`)

The **ledger** install additionally runs `galaxy-ledger install`, which registers hooks and skills into your Claude Code settings (`~/.claude/settings.json`).

### Installing individual tools

```bash
# Install just one tool
cd tools/statusline && make install
cd tools/ledger && make install
cd tools/galaxy && make install
```

### Ledger note

The ledger tool requires Crystal shards (SQLite bindings). If you see `can't find file 'db'` errors, run `shards install` inside `tools/ledger/` before building:

```bash
cd tools/ledger
shards install
make install
```

## Tool Overview

### GalaxyApp

A native macOS (SwiftUI) terminal app purpose-built for Claude Code sessions. Uses a vendored and patched [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal rendering with Galaxy-specific improvements (FillStroke font thickening, sRGB color rendering, bold foreground colors from themes).

See [GalaxyApp/SETUP.md](GalaxyApp/SETUP.md) for detailed setup and troubleshooting.

### statusline

A customizable status line for Claude Code sessions that displays:

- Working directory (width-adaptive)
- Git branch and status (ahead/behind, dirty, staged, stashed)
- Context window usage (visual progress bar with color thresholds)
- Model name and session cost

**Example output:**
```
~/projects/galaxy[main=*] | ████████████░░░░░░░░ 62% | Sonnet | $0.42
```

See [tools/statusline/README.md](tools/statusline/README.md) for detailed documentation.

### ledger

A persistent context ledger that survives context resets within a Claude Code session. Automatically captures:

- Guidelines extracted from config files
- Implementation plan context
- Key decisions and their rationale
- Session file access history

Installs Claude Code hooks (SessionStart, Stop, PostToolUse, UserPromptSubmit) and skills (spend, snapshot, artifact, prune).

### galaxy

Core CLI tool for Galaxy operations.

## Development

Each tool is self-contained in its own directory under `tools/`. All CLI tools are written in [Crystal](https://crystal-lang.org/). GalaxyApp is a Swift/SwiftUI macOS application.

### Make Targets

```bash
# CLI tools
make all                  # Build all CLI tools (release)
make clean                # Clean all build artifacts

# Per-tool targets (statusline, ledger, galaxy)
make <tool>-build         # Release build
make <tool>-dev           # Dev build (faster, no optimizations)
make <tool>-test          # Run specs
make <tool>-check         # Lint + dev build + test
make <tool>-install       # Check + release build + install
make <tool>-clean         # Remove build artifacts

# GalaxyApp
make app-build            # Debug build
make app-release          # Release build
make app-clean            # Clean Xcode derived data
```

### Project Structure

```
galaxy/
├── Makefile                  # Root orchestration for all components
├── GalaxyApp/                # Native macOS terminal app
│   ├── GalaxyApp/            # Swift source files
│   ├── Resources/            # App resources (icons, etc.)
│   ├── Vendor/               # Vendored dependencies (gitignored)
│   ├── scripts/              # Setup and patch scripts
│   ├── project.yml           # XcodeGen project spec
│   └── SETUP.md              # Detailed setup guide
└── tools/
    ├── galaxy/               # Core CLI tool
    ├── ledger/               # Context ledger tool
    └── statusline/           # Status line tool
```

## License

MIT License - see [LICENSE](LICENSE) for details.
