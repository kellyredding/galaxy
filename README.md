# Galaxy

**Galaxy brain for Claude Code** — Multi-agent orchestration tools for Claude Code.

## Tools

| Tool | Description | Status |
|------|-------------|--------|
| [statusline](tools/statusline/) | Customizable status line with context usage, git status, and more | Active |

## Quick Install

```bash
# Clone and build
git clone https://github.com/kellyredding/galaxy.git
cd galaxy

# Build and install all tools
make statusline-install
make ledger-install
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
    └── statusline/           # Status line tool
```

## License

MIT License - see [LICENSE](LICENSE) for details.
