# galaxy-statusline

Customizable status line for Claude Code sessions. Renders the working
directory, git status, context-window usage, model name, session cost, and
current time on two width-adaptive lines that gracefully degrade on narrow
terminals.

## Commands

| Command | Description |
|---------|-------------|
| `render` | Render the status line (reads JSON from stdin) |
| `config` | Show the current configuration |
| `config help` | Full configuration documentation |
| `config set KEY VAL` | Set a configuration value |
| `config get KEY` | Get a configuration value |
| `config reset` | Reset configuration to defaults |
| `config path` | Show the config file location |
| `update` | Update to the latest GitHub release |
| `update preview` | Preview an update without making changes |
| `update force` | Reinstall the latest release even if current |
| `version` | Show the version |
| `help` | Show CLI usage |

If invoked with no arguments and stdin has data, it renders implicitly
(equivalent to `render`).

## Claude Code Integration

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/galaxy/bin/galaxy-statusline",
    "padding": 0
  }
}
```

## Example Output

```
WIDE (120+ cols):
~/projects/kajabi/kajabi-products[main=*] | ████████████████░░░░ 78% | Sonnet | $0.42 | 6:41 AM

MEDIUM (80-119 cols):
~/p/k/kajabi-products[main=*] | ██████████░░░░ 78% | Sonnet | $0.42

NARROW (60-79 cols):
kajabi-products[main=*] | ██████░░ 78% | Son

VERY NARROW (<60 cols):
[main=*] | ████░░ 78%
```

The session line shrinks in this order: shrink the context bar → drop
the time → drop the cost → drop the model. The context bar and
percentage are always preserved.

## Configuration

Configuration lives at `~/.claude/galaxy/statusline/config.json`. Run
`galaxy-statusline config help` for the full reference.

### Branch Styles

| Style | Example | Description |
|-------|---------|-------------|
| `symbolic` | `[main=*]` | Compact symbols: `=` synced, `<` behind, `>` ahead, `*` dirty, `+` staged |
| `arrows` | `main ↑2↓3` | Exact ahead/behind counts with arrows |
| `minimal` | `main*` | Branch name only, `*` if dirty |

### Colors

Colors can be set to:
- Named colors: `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`
- Bright variants: `bright_red`, `bright_green`, etc.
- Bold modifier: `bold:green`, `bold:yellow`
- Default terminal color: `default`

### Example Configuration

```json
{
  "version": "0.0.1",
  "colors": {
    "directory": "bold:yellow",
    "branch": "green",
    "context_normal": "green",
    "context_warning": "yellow",
    "context_critical": "red",
    "model": "bright_cyan",
    "cost": "bright_green",
    "time": "bold:red"
  },
  "branch_style": "symbolic",
  "context_thresholds": {
    "warning": 60,
    "critical": 80
  },
  "layout": {
    "min_width": 60,
    "context_bar_min_width": 10,
    "context_bar_max_width": 20,
    "show_cost": true,
    "show_model": true,
    "show_time": true,
    "directory_style": "smart"
  }
}
```

## Installation

Download the latest binary from
[Releases](https://github.com/kellyredding/galaxy/releases) and place it
in your PATH:

```bash
# Download tarball and checksum (check Releases page for latest version)
# Use darwin-arm64 for Apple Silicon, darwin-amd64 for Intel
curl -LO https://github.com/kellyredding/galaxy/releases/download/statusline-vX.X.X/galaxy-statusline-X.X.X-darwin-arm64.tar.gz
curl -LO https://github.com/kellyredding/galaxy/releases/download/statusline-vX.X.X/galaxy-statusline-X.X.X-darwin-arm64.tar.gz.sha256

# Verify checksum (should say "OK")
shasum -a 256 -c galaxy-statusline-X.X.X-darwin-arm64.tar.gz.sha256

# Extract and install
tar -xzf galaxy-statusline-X.X.X-darwin-arm64.tar.gz
mkdir -p ~/.claude/galaxy/bin
mv galaxy-statusline-X.X.X-darwin-arm64 ~/.claude/galaxy/bin/galaxy-statusline
chmod +x ~/.claude/galaxy/bin/galaxy-statusline

# Clean up
rm galaxy-statusline-X.X.X-darwin-arm64.tar.gz galaxy-statusline-X.X.X-darwin-arm64.tar.gz.sha256
```

Or build from source (requires Crystal):

```bash
git clone https://github.com/kellyredding/galaxy.git
cd galaxy/tools/statusline
make install
```

## Development

```bash
cd tools/statusline
make check    # Format, build dev binary, run specs, lint
make install  # Build release and install to ~/.claude/galaxy/bin/
```

## License

MIT License - see [LICENSE](LICENSE) for details.
