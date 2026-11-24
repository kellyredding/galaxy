# Contributing to galaxy

Galaxy is a personal toolkit with one developer, so there are no pull requests:
work lands on the `development` branch by fast-forward, and `main` catches up
at each release. Issues are welcome.

[SETUP.md](SETUP.md) covers building from source, installing your changes,
branches and releases. This file covers the conventions code here follows.

## Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/kellyredding/galaxy.git
   cd galaxy
   git checkout development
   ```

2. Build and test a tool:
   ```bash
   cd tools/statusline
   make check
   ```

## Project Structure

Each CLI tool lives in its own directory under `tools/`, and the macOS app in
`GalaxyApp/`. They are released together as one suite version (`VERSION` at
the repository root); each tool still records its own version.

```
tools/
└── statusline/
    ├── README.md           # Tool documentation
    ├── version.txt         # This tool's version (VERSION.txt in some tools)
    ├── Makefile            # Build configuration
    ├── shard.yml           # Crystal dependencies
    ├── src/                # Source code
    └── spec/               # Tests
```

## Development Workflow

Branches, landing work and releasing are described in
[SETUP.md](SETUP.md#branches). Before committing:

```bash
cd tools/<tool>
make check  # Runs lint + build + test
```

### Code Style

- Crystal code is formatted using `crystal tool format`
- Run `make format` to auto-format
- Run `make lint` to check formatting

### Testing

- Unit tests live in `spec/`
- Integration tests live in `spec/integration/`
- Run `make test` to run all tests
- Run `make check` to run lint + build + test

### This repository is public

It is a personal toolkit, so it names its own author and its own paths freely.
It must not name an employer, their repositories, or their infrastructure —
and those arrive through example output and spec fixtures rather than through
anything deliberate, because the easiest example to write is whatever happened
to be on screen.

Use placeholders instead:

| For | Use |
|---|---|
| a project directory | `~/projects/my-app` |
| an organisation and repository | `~/projects/acme/acme-products` |
| a home directory in example output | `/Users/you` |

`make audit` enforces this from the repository root and runs as part of
`make check`. It has two layers: structural patterns in
`scripts/check-disclosure.sh`, which describe the *shape* of a leak and so
catch cases nobody anticipated; and a literal denylist kept deliberately
outside the repository, since a committed list of forbidden strings would be
the disclosure it prevents. Point at it with `GALAXY_DENYLIST`, or leave it at
`~/.claude/galaxy/denylist.txt` — sharing one file with the other public repos
rather than keeping copies that drift. Absent, the audit fails closed rather
than covering less than it claims; `GALAXY_ALLOW_NO_DENYLIST=1` accepts the
structural layer alone.

The audit scans git-*tracked* files, so a new file is invisible to it until
staged. And a leak that reaches a commit is not fixable by a later one — git
keeps the object. Run it before committing, not after.

Build output is a common way for this to go wrong: a compiled binary embeds the
paths it was built from. Keep binaries out of the tree.

## Adding a New Tool

1. Create the tool directory:
   ```bash
   mkdir -p tools/newtool/{src,spec}
   ```

2. Copy scaffolding from an existing tool (e.g., statusline)

3. Update the root Makefile to include the new tool

4. Add the tool to the root README.md and to `TOOLS` in `bin/package`, and to
   `SETUP_TOOLS` in `install.sh` if its `install` subcommand sets anything up

## Release Process

Galaxy is released as a whole; see [SETUP.md](SETUP.md#release).

## Questions?

Open an issue for questions or discussion.
