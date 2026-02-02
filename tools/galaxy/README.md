# galaxy

Launch Galaxy sessions from the terminal.

## Features

- **Directory-aware sessions** — Sessions start in the directory where you run `galaxy`
- **Native macOS integration** — Opens Galaxy.app via URL scheme
- **Self-updating** — Update to latest version with `galaxy update`

## Installation

Download the latest binary from [Releases](https://github.com/kellyredding/galaxy/releases) and place it in your PATH:

```bash
# Download tarball and checksum (check Releases page for latest version)
# Use darwin-arm64 for Apple Silicon, darwin-amd64 for Intel
curl -LO https://github.com/kellyredding/galaxy/releases/download/galaxy-vX.X.X/galaxy-X.X.X-darwin-arm64.tar.gz
curl -LO https://github.com/kellyredding/galaxy/releases/download/galaxy-vX.X.X/galaxy-X.X.X-darwin-arm64.tar.gz.sha256

# Verify checksum (should say "OK")
shasum -a 256 -c galaxy-X.X.X-darwin-arm64.tar.gz.sha256

# Extract and install
tar -xzf galaxy-X.X.X-darwin-arm64.tar.gz
mkdir -p ~/.claude/galaxy/bin
mv galaxy-X.X.X-darwin-arm64 ~/.claude/galaxy/bin/galaxy
chmod +x ~/.claude/galaxy/bin/galaxy

# Add to PATH (add to ~/.zshrc or ~/.bashrc)
export PATH="$HOME/.local/bin:$PATH"

# Create symlink for PATH access
mkdir -p ~/.local/bin
ln -sf ~/.claude/galaxy/bin/galaxy ~/.local/bin/galaxy

# Clean up
rm galaxy-X.X.X-darwin-arm64.tar.gz galaxy-X.X.X-darwin-arm64.tar.gz.sha256
```

Or build from source (requires Crystal):

```bash
git clone https://github.com/kellyredding/galaxy.git
cd galaxy/tools/galaxy
make install
```

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
cd ~/projects/kajabi/kajabi-products

# Launch Galaxy session
galaxy

# Galaxy.app opens (or activates if already running)
# A new Claude Code session starts in kajabi-products/
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
