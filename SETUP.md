# Developing Galaxy

To use Galaxy, install it with the one-line script in the
[README](README.md#installation). This guide is for building it from source,
installing your changes, and making releases.

## Prerequisites

- **Apple Silicon, macOS 26** or later
- **Xcode** with Swift 6, pointed at by the developer tools:
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept
  ```
- **Xcode's Metal toolchain** — SwiftTerm compiles a Metal shader, and a build
  without it fails with "missing Metal Toolchain". It is a separate download:
  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```
- **XcodeGen** — generates the Xcode project from `GalaxyApp/project.yml`:
  ```bash
  brew install xcodegen
  ```
- **Crystal** (`crystal` and `shards`) for the CLI tools, via
  [mise](https://mise.jdx.dev/):
  ```bash
  mise install crystal@latest
  ```
- **Node** — the app build syntax-checks the JavaScript it ships.
- **Claude Code**, installed and signed in — the ledger's specs call
  `claude -p`.

For releases, also the 1Password CLI (`op`) and the GitHub CLI (`gh`), both
signed in.

## Install your changes

From anywhere in your checkout:

```bash
galaxy update --local
```

That builds every CLI tool and a Release Galaxy.app from your working tree,
uncommitted changes included, and installs them the way a release is
installed: the tools into `~/.claude/galaxy/bin` (linked into
`~/.local/bin`), the app into `~/Applications/Galaxy.app`. A running Galaxy
keeps running; restart it to switch. `galaxy update` puts you back on the
latest release.

The app is signed with the release identity when 1Password can provide it,
and ad-hoc otherwise. macOS keys an app's privacy permissions to its
signature, so an ad-hoc build asks for them again.

Underneath, that is `bin/package --local`, which writes
`dist/galaxy-darwin-arm64.tar.gz`, and `install.sh --from` that archive.

## Build and check without installing

```bash
make check                 # disclosure audit, then every tool's lint + specs
make app-check             # the app's Debug build and its smoke checks
make -C tools/ledger dev   # one tool's development binary
```

Run `make check` before committing. `make audit` on its own is quick: this
repository is public, and it refuses employer- and deployment-specific details.

## Release

Releases are made from `main` once a version bump has merged:

1. Bump `VERSION` (the suite version) and any tool's `version.txt` that
   changed, in a PR.
2. In the same PR, add `release-notes/vX.Y.Z.md`: the changes since the last
   release, grouped by what a user notices. Each group is a `###` heading led
   by an emoji, with two or three bullets under it. Ask your agent to draft it
   from `git log <last tag>..HEAD`, then edit it. See
   `release-notes/v0.1.0.md` for the shape.
3. After it merges, on an up-to-date `main`, from a real terminal (1Password's
   approval does not reach a shell without one):
   ```bash
   bin/release --dry-run   # everything but the tag; prints the release description
   bin/release             # tag vX.Y.Z and publish the GitHub release
   ```

`bin/release` refuses without the notes file. It runs every check, packages,
verifies the archive (versions, a clean tree, the signing authority), then
tags and publishes, with the notes under the install instructions as the
release description. Users get it with `galaxy update`.

### The signing identity

Releases are signed with a self-signed identity, "Galaxy Release Signing",
kept only in 1Password (Private vault, personal account). Packaging fetches it
into a throwaway keychain and deletes that afterwards.

```bash
bin/signing-identity show     # its SHA-1
bin/signing-identity create   # first time only; refuses if it exists
```

Every release must be signed with the same identity: macOS keys privacy
permissions to it, so a new one makes every user grant them again.
