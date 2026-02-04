# galaxy-ledger

A context continuity system for Claude Code that automatically tracks learnings, decisions, and file interactions throughout a session, then restores them after `/clear` or compaction.

## Features

- **Learning extraction** - Captures insights, decisions, and discoveries from conversations
- **User direction capture** - Tracks preferences and constraints you specify
- **File operation tracking** - Records reads, edits, and writes
- **Context restoration** - Restores relevant context after `/clear` or auto-compact
- **SQLite storage** - Full-text search across all sessions

## Installation

```bash
git clone https://github.com/kellyredding/galaxy.git
cd galaxy/tools/ledger
make install
```

## Hook Installation

Ledger uses Claude Code hooks for automatic tracking:

```bash
galaxy-ledger hooks install   # Add hooks to ~/.claude/settings.json
galaxy-ledger hooks status    # Check installed hooks
galaxy-ledger hooks uninstall # Remove hooks
```

## Commands

```bash
galaxy-ledger list                    # List recent entries
galaxy-ledger search "query"          # Search the ledger (FTS)
galaxy-ledger session list            # List all sessions
galaxy-ledger session show SESSION_ID # Show session details
galaxy-ledger buffer show             # Show pending buffer entries
galaxy-ledger config                  # Show current config
```

## Hook Recursion Prevention

Ledger extracts learnings by spawning `claude -p` one-shot subprocesses. Without safeguards, this would cause infinite recursion: the subprocess triggers hooks → hooks spawn extraction → extraction triggers hooks → ∞

**Solution:** The `GALAXY_SKIP_HOOKS` environment variable.

When ledger spawns Claude CLI for extraction, it sets `GALAXY_SKIP_HOOKS=1`. All hook handlers check for this and return early:

```crystal
return if ENV["GALAXY_SKIP_HOOKS"]? == "1"
```

This is a Galaxy-wide convention for any tool that spawns Claude CLI subprocesses.

## Development

```bash
make check    # lint + build + test
make dev      # build dev binary
make test     # run tests only
```

## License

MIT License - see [LICENSE](../../LICENSE) for details.
