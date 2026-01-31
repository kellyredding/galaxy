# Releasing galaxy-statusline

This document describes how to create releases and distribute binaries.

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

From your primary development machine (ARM Mac):

```bash
bin/release
```

This will:
- Sync version to `shard.yml` and source code
- Build optimized release binary
- Run test suite
- Create tarball with SHA256 checksum
- Commit version bump
- Create and push git tag
- Create GitHub release with macOS ARM64 binary

### 3. Add Additional Platforms (Optional)

To add binaries for other platforms, run `bin/release-add` on each target machine:

**On an Intel Mac:**
```bash
git pull origin main
bin/release-add
# Uploads galaxy-statusline-X.Y.Z-darwin-amd64.tar.gz
```

**On a Linux x64 machine:**
```bash
git pull origin main
bin/release-add
# Uploads galaxy-statusline-X.Y.Z-linux-amd64.tar.gz
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
- `galaxy-statusline-X.Y.Z-<os>-<arch>.tar.gz` - Compressed binary
- `galaxy-statusline-X.Y.Z-<os>-<arch>.tar.gz.sha256` - Checksum file

## Verifying Downloads

Users can verify download integrity:

```bash
shasum -a 256 -c galaxy-statusline-0.1.0-darwin-arm64.tar.gz.sha256
```

## Version Locations

Version is defined in three places, kept in sync by `bin/release`:
- `VERSION.txt` - Source of truth
- `shard.yml` - Crystal package version
- `src/galaxy_statusline.cr` - `VERSION` constant
