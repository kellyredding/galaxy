# galaxy-agents

Subagent lifecycle tracking for Claude Code. Records when agents start, stop, fail, or are abandoned, with timeline event publishing and real-time socket notifications.

## Commands

| Command | Description |
|---------|-------------|
| `start` | Record a new agent starting |
| `stop` | Record an agent stopping (determines success/failure) |
| `abandon` | Mark all running agents as abandoned |
| `list` | List agents for a session |
| `show` | Show full agent detail |
| `stats` | Get agent counts by status (JSON) |
| `running` | Get count of running agents (JSON) |
| `backup` | Manage database backups |
| `version` | Show version |

## Usage

```bash
# Start tracking an agent
galaxy-agents start \
  --ledger-session-id 1 \
  --agent-id abc123 \
  --agent-type Explore \
  --parent-transcript-path /path/to/transcript.jsonl

# Stop an agent (reads last message from stdin)
echo "Found 15 files" | galaxy-agents stop \
  --ledger-session-id 1 \
  --agent-id abc123 \
  --agent-transcript-path /path/to/agent.jsonl \
  --last-message-stdin

# Abandon orphaned agents at session end
galaxy-agents abandon --ledger-session-id 1

# List agents
galaxy-agents list --ledger-session-id 1 --json

# Get stats
galaxy-agents stats --ledger-session-id 1 --json
```

## Data

- **Database**: `~/.claude/galaxy/data/agents.db`
- **Config**: `~/.claude/galaxy/agents/config.json`
- **Backups**: `~/.claude/galaxy/data/backups/agents/`

## Timeline Events

| Event | Description |
|-------|-------------|
| `agent:started` | Agent spawned (durationStart) |
| `agent:stopped` | Agent completed successfully (durationEnd) |
| `agent:failed` | Agent completed with failure (durationEnd) |
| `agent:abandoned` | Orphaned agent cleaned up (durationEnd) |

## Socket Events

| Event | Description |
|-------|-------------|
| `agent.started` | Real-time notification of agent spawn |
| `agent.stopped` | Real-time notification of successful stop |
| `agent.failed` | Real-time notification of failure |
| `agent.abandoned` | Real-time notification of abandonment |

## Development

```bash
cd tools/agents
make check    # Format, build dev binary, run specs, lint
make install  # Build release and install to ~/.claude/galaxy/bin/
```
