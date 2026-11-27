# Developing Galaxy

To use Galaxy, install it with the one-line script in the
[README](README.md#installation). This guide is for building it from source,
installing your changes, and making releases.

## Prerequisites

- **Apple Silicon, macOS 26** or later. That is for building; a release runs on
  Apple Silicon and Intel Macs with macOS 15 or later
  (`bin/lib/universal.sh`), and nothing is built on an Intel Mac.
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

The app is signed with the release identity, which the 1Password CLI (`op`)
reads from 1Password; without `op` the build refuses. macOS keys an app's
privacy permissions to its signature, so a build signed any other way loses
them.

Underneath, that is `bin/package --local`, which writes
`dist/galaxy-darwin.tar.gz`, and `install.sh --from` that archive. A `galaxy`
installed before the archive took that name looks for the older
`galaxy-darwin-arm64.tar.gz`, so the first time, run the two steps by hand:

```bash
bin/package --local && ./install.sh --from dist/galaxy-darwin.tar.gz
```

## Apple Silicon and Intel

Release tools and the release app hold both architectures; development builds
(`make dev`, `make app-build`) stay native, so specs and day-to-day builds are
no slower. Each tool's `build` compiles natively, cross-compiles for Intel and
joins the two with `lipo` (`tools/build.mk`); the app's `release` builds both
(`GalaxyApp/Makefile`). The minimum macOS lives in four places that must move
together: `tools/build.mk`, `GalaxyApp/project.yml`, `install.sh`'s
`MIN_MACOS`, and `bin/lib/universal.sh`. `bin/package` and `bin/release`
refuse any binary missing an architecture, built for a newer macOS, or loading
a library from outside the system, so a floor moved in one place but not the
others fails there.

## Build and check without installing

```bash
make check                 # disclosure audit, then every tool's lint + specs
make app-check             # the app's Debug build and its smoke checks
make -C tools/ledger dev   # one tool's development binary
```

Run `make check` before committing. `make audit` on its own is quick: this
repository is public, and it refuses employer- and deployment-specific details.

## Branches

`development` is where work lands. `main` is the release branch, and it only
ever moves by fast-forwarding to `development` at a release. Galaxy has one
developer, so there are no pull requests.

- Start each piece of work on a branch off an up-to-date `development`:
  ```bash
  git checkout development && git pull --ff-only
  git checkout -b kr/feature-name01-task-name
  ```
- Land it by fast-forwarding `development` once its checks pass, then delete
  the branch:
  ```bash
  git checkout development && git pull --ff-only
  git merge --ff-only kr/feature-name01-task-name
  git push origin development
  git branch -d kr/feature-name01-task-name
  ```
  If the fast-forward refuses, `development` has moved: rebase the branch onto
  it and try again, rather than merging.
- Nothing is ever committed on `main` directly.

## Release

Releases are made from `main` after it catches up with `development`:

1. On a branch off `development`, bump `VERSION` (the suite version) and any
   tool's `version.txt` that changed.
2. In the same branch, add `release-notes/vX.Y.Z.md`: the changes since the
   last release, grouped by what a user notices. Each group is a `###` heading
   led by an emoji, with two or three bullets under it. Ask your agent to draft
   it from `git log <last tag>..HEAD`, then edit it. See
   `release-notes/v0.1.0.md` for the shape.
3. Land that branch on `development` (above), then fast-forward `main` to it:
   ```bash
   git checkout main && git pull --ff-only
   git merge --ff-only development
   git push origin main
   ```
   If that fast-forward refuses, `main` has a commit `development` lacks; sort
   that out before releasing rather than merging.
4. On that `main`, from a terminal that can show 1Password's prompt:
   ```bash
   bin/release --dry-run   # everything but the tag; prints the release description
   bin/release             # tag vX.Y.Z and publish the GitHub release
   ```

`bin/release` refuses without the notes file. It runs every check, packages,
verifies the archive (versions, commit, a clean tree, the signing authority,
both architectures and the minimum macOS of every binary),
then tags and publishes, with the notes under the install instructions as the
release description. Users get it with `galaxy update`. It commits nothing,
only a tag, so `main` and `development` stay on the same commit; switch back to
`development` afterwards.

A release right after a dry run of the same commit reuses that run's archive:
it skips the checks and the build (several minutes), verifies the archive
again, and publishes. Any new commit means a full run. `bin/release --fresh`
forces one anyway, say after changing a toolchain.

If a release fails partway, run `bin/release` again. It picks up where the
earlier run stopped: a tag that was made but not pushed is pushed, and a
GitHub release left incomplete gets its files and notes and is published.
Once the release is complete it says so and exits, so running it twice is
harmless. A tag for this version on a different commit is refused: bump
`VERSION` instead.

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
