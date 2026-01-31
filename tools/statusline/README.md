# galaxy-statusline

A customizable status line for Claude Code sessions that displays working directory, git status, context usage, and model information.

## Features

- **Working directory** with smart path abbreviation
- **Git status** showing branch, ahead/behind, dirty/staged/stashed state
- **Context usage** with visual progress bar and color thresholds
- **Model name** and session cost
- **Width-adaptive** layout that gracefully degrades on narrow terminals
- **Fully configurable** colors, styles, and thresholds

## Installation

### From Source

```bash
cd tools/statusline
make install
```

This installs the binary to `~/.claude/galaxy/bin/galaxy-statusline`.

### Manual Installation

```bash
make build
cp build/galaxy-statusline ~/.claude/galaxy/bin/
```

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

## Usage

### CLI Commands

```bash
galaxy-statusline                    # If stdin has data -> render, else -> help
galaxy-statusline render             # Explicit render (reads stdin JSON)
galaxy-statusline config             # Show current config
galaxy-statusline config help      # Configuration documentation
galaxy-statusline config set KEY VAL # Set a config value
galaxy-statusline config get KEY     # Get a config value
galaxy-statusline config reset       # Reset to defaults
galaxy-statusline config path        # Show config file location
galaxy-statusline version            # Show version
galaxy-statusline help               # Show help
```

### Example Output

```
WIDE (120+ cols):
~/projects/kajabi/kajabi-products[main=*] | ████████████████░░░░ 78% | Sonnet | $0.42

MEDIUM (80-119 cols):
~/p/k/kajabi-products[main=*] | ██████████░░░░ 78% | Sonnet

NARROW (60-79 cols):
kajabi-products[main=*] | ██████░░ 78% | Son

VERY NARROW (<60 cols):
[main=*] | ████░░ 78%
```

## Configuration

Configuration is stored at `~/.claude/galaxy/statusline/config.json`.

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

### Configuration Reference

```bash
galaxy-statusline config help  # Full configuration documentation
```

### Example Configuration

```json
{
  "version": "0.0.1",
  "colors": {
    "directory": "bold:yellow",
    "branch": "green",
    "context_normal": "green",
    "context_warning": "yellow",
    "context_critical": "red"
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
    "directory_style": "smart"
  }
}
```

## Development

```bash
make check    # lint + build + test
make dev      # build dev binary
make test     # run tests only
make format   # auto-format code
```

## License

MIT License - see [LICENSE](LICENSE) for details.
