# Releasing galaxy

This document describes how to create releases and distribute binaries.

## Multi-Tool Repository

Galaxy is a multi-tool repository. Each tool has independent releases with tool-prefixed tags:

- `galaxy-v0.1.0` - galaxy CLI releases
- `statusline-v0.1.0` - statusline releases

This allows each tool to version independently while sharing a single repository.

## Prerequisites

- Crystal installed (`crystal --version`)
- GitHub CLI installed and authenticated (`gh auth status`)
- Push access to the repository

## First-Time Setup

Make the release scripts executable:

```bash
chmod +x bin/release bin/release-add
```

## Creating a New Release

### 1. Update the Version

Edit `VERSION.txt` with the new version number:

```bash
echo "0.1.0" > VERSION.txt
```

Version must be in `X.Y.Z` format (semver).

### 2. Run the Release Script

From your primary development machine (ARM Mac), within the `tools/galaxy/` directory:

```bash
bin/release
```

This will:
- Sync version to `shard.yml` and source code
- Build optimized release binary
- Run test suite
- Create tarball with SHA256 checksum
- Commit version bump
- Create and push git tag (`galaxy-vX.Y.Z`)
- Create GitHub release with macOS ARM64 binary

### 3. Add Additional Platforms (Optional)

To add binaries for other platforms, run `bin/release-add` on each target machine:

**On an Intel Mac:**
```bash
git pull origin main
cd tools/galaxy
bin/release-add
# Uploads galaxy-X.Y.Z-darwin-amd64.tar.gz
```

**On a Linux x64 machine:**
```bash
git pull origin main
cd tools/galaxy
bin/release-add
# Uploads galaxy-X.Y.Z-linux-amd64.tar.gz
```

## Platform Detection

The `bin/release-add` script auto-detects the current platform:

| Machine | Artifact Name |
|---------|---------------|
| Apple Silicon Mac | `darwin-arm64` |
| Intel Mac | `darwin-amd64` |
| Linux x64 | `linux-amd64` |
| Linux ARM64 | `linux-arm64` |

## Release Artifacts

Each release includes:
- `galaxy-X.Y.Z-<os>-<arch>.tar.gz` - Compressed binary
- `galaxy-X.Y.Z-<os>-<arch>.tar.gz.sha256` - Checksum file

## Tag Format

Tags follow the pattern `{tool}-v{version}`:
- Tag: `galaxy-v0.1.0`
- Release title: `galaxy v0.1.0`

This enables the self-update feature to find the correct release for each tool in the multi-tool repository.

## Verifying Downloads

Users can verify download integrity:

```bash
shasum -a 256 -c galaxy-0.1.0-darwin-arm64.tar.gz.sha256
```

## Version Locations

Version is defined in three places, kept in sync by `bin/release`:
- `VERSION.txt` - Source of truth
- `shard.yml` - Crystal package version
- `src/galaxy.cr` - `VERSION` constant

## Self-Update

Users can update to the latest version with:

```bash
galaxy update           # Update to latest
galaxy update preview   # Preview without changes
galaxy update force     # Reinstall even if current
```

The update command fetches releases from GitHub, filters for `galaxy-v*` tags, and installs the latest matching release.
