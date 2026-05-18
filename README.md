# Galaxy

**Galaxy brain for Claude Code** — Multi-agent orchestration tools for Claude Code.

## Tools

| Tool | Description | Status |
|------|-------------|--------|
| [statusline](tools/statusline/) | Customizable status line with context usage, git status, and more | Active |
| [ledger](tools/ledger/) | Continuous context management for Claude Code | Active |
| [snapshots](tools/snapshots/) | Session snapshot management for Claude Code | Active |
| [artifacts](tools/artifacts/) | Session artifact management for Claude Code | Active |
| [timeline](tools/timeline/) | Session timeline event recording for Claude Code | Active |
| [agents](tools/agents/) | Subagent lifecycle tracking for Claude Code | Active |
| [diff](tools/diff/) | Structured diff capture for code review in Galaxy.app | Active |
| [galaxy](tools/galaxy/) | Terminal CLI launcher for Galaxy.app sessions (directory-aware, URL-scheme integration, self-updating) | Active |

## Quick Install

```bash
# Clone and build
git clone https://github.com/kellyredding/galaxy.git
cd galaxy

# Build and install all tools
make statusline-install
make ledger-install
make snapshots-install
make artifacts-install
make timeline-install
make agents-install
make diff-install
make galaxy-install
```

Or build individual tools:

```bash
cd tools/statusline
make install
```

**Installation locations:**
- Binaries: `~/.claude/galaxy/bin/`
- Symlinks: `~/.bin/local/` (add to your PATH for easy access)

## Tool Overview

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

### snapshots

Session snapshot management for Claude Code. Captures and restores session context snapshots, enabling persistent context across sessions.

See [tools/snapshots/](tools/snapshots/) for detailed documentation.

### artifacts

Session artifact management for Claude Code. Stores, retrieves, and manages documents, data exports, diagrams, and other files produced during a session.

See [tools/artifacts/](tools/artifacts/) for detailed documentation.

### timeline

Session timeline event recording for Claude Code. Records timestamped events across the Galaxy ecosystem, providing a unified chronological log of session activity (starts, stops, clears, snapshots, etc.).

See [tools/timeline/](tools/timeline/) for detailed documentation.

### agents

Subagent lifecycle tracking for Claude Code. Records when agents start, stop, fail, or are abandoned, with timeline event publishing and real-time socket notifications.

See [tools/agents/](tools/agents/) for detailed documentation.

### diff

Structured diff capture for code review in Galaxy.app. Parses `git diff` output, reads full before/after file contents, and emits `.gdiff` JSON to stdout. Pipe into `galaxy-artifacts save` to produce an annotatable diff artifact with syntax highlighting, hunk overlay, and line-level annotations.

See [tools/diff/](tools/diff/) for detailed documentation.

## Development

Each tool is self-contained in its own directory under `tools/`. Tools may be written in different languages, but currently all are written in [Crystal](https://crystal-lang.org/).

### Prerequisites

- Crystal >= 1.0.0
- Git

### Building All Tools

```bash
make all                  # Build all tools
make statusline-build     # Build statusline
make statusline-test      # Test statusline
make statusline-check     # Lint + build + test statusline
```

### Project Structure

```
galaxy/
├── README.md                 # This file
├── LICENSE                   # MIT License
├── CONTRIBUTING.md           # Development guidelines
├── Makefile                  # Root orchestration
├── bin/                      # Root scripts (future)
├── shared/                   # Shared code (if needed)
└── tools/
    ├── statusline/           # Status line tool
    ├── ledger/               # Continuous context management
    ├── snapshots/            # Session snapshot management
    ├── artifacts/            # Session artifact management
    ├── timeline/             # Session timeline events
    ├── agents/               # Subagent lifecycle tracking
    ├── diff/                 # Structured diff capture
    └── galaxy/               # Terminal CLI launcher for Galaxy.app
```

## License

MIT License - see [LICENSE](LICENSE) for details.
