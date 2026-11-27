# galaxy

Launch Galaxy sessions from the terminal.

## Features

- **Directory-aware sessions** — Sessions start in the directory where you run `galaxy`
- **Native macOS integration** — Opens Galaxy.app via URL scheme
- **Self-updating** — Update to latest version with `galaxy update`

## Installation

`galaxy` is installed with the rest of Galaxy; see the
[installation steps](../../README.md#installation).

## Prerequisites

- **Galaxy.app** installed in `/Applications`

## Usage

### CLI Commands

```bash
galaxy                    # Open Galaxy.app, create session in current directory
galaxy version            # Show version
galaxy update             # Update to latest version
galaxy update preview     # Preview update without changes
galaxy update force       # Reinstall latest version
galaxy help               # Show help
```

### Example Workflow

```bash
# Navigate to your project
cd ~/projects/acme/acme-products

# Launch Galaxy session
galaxy

# Galaxy.app opens (or activates if already running)
# A new Claude Code session starts in acme-products/
```

## How It Works

The CLI opens Galaxy.app via URL scheme, passing the current directory:

```
galaxy://new-session?path=/Users/you/projects/my-app
```

If Galaxy.app isn't running, macOS launches it. If it's already running, a new session is created in the specified directory.

## Development

```bash
make check    # lint + build + test
make dev      # build dev binary
make test     # run tests only
make format   # auto-format code
```

## License

MIT License - see [LICENSE](LICENSE) for details.
