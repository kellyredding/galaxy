#!/usr/bin/env bash
# Installs or updates Galaxy: the CLI tools and Galaxy.app.
#
#   curl -fsSL https://raw.githubusercontent.com/kellyredding/galaxy/main/install.sh | bash
#
# `galaxy update` runs this same script. Options (after `bash -s --` when piped):
#
#   --version X.Y.Z   Install that release instead of the latest
#   --from ARCHIVE    Install a local archive written by bin/package
#   --preview         Show what would change, change nothing
#   --force           Reinstall even when already up to date
#   --no-register     Skip Launch Services registration (sandboxed tests)
#
# Never launches, quits or restarts Galaxy.
set -euo pipefail

REPO="kellyredding/galaxy"
ASSET="galaxy-darwin-arm64.tar.gz"
MIN_MACOS=26
GALAXY_HOME="$HOME/.claude/galaxy"
BIN_DIR="$GALAXY_HOME/bin"
LOCAL_BIN="$HOME/.local/bin"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Galaxy.app"
INSTALLED_MANIFEST="$GALAXY_HOME/installed-manifest.json"
# Tools whose `install` subcommand sets up skills or hooks after a copy.
SETUP_TOOLS=(ledger artifacts diff files)
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

version=""
from=""
preview=false
force=false
register=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:?--version needs X.Y.Z}"; version="${version#v}"; shift ;;
    --from) from="${2:?--from needs an archive path}"; shift ;;
    --preview|preview) preview=true ;;
    --force|force) force=true ;;
    --no-register) register=false ;;
    -h|--help|help) sed -n '2,15p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' \
                      || echo "See https://github.com/$REPO/blob/main/install.sh"; exit 0 ;;
    *) echo "install.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done

if [[ -t 1 ]]; then BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; NC=$'\033[0m'
else BOLD=""; RED=""; GREEN=""; NC=""; fi
say() { printf '%s\n' "$*"; }
step() { printf '  %s\n' "$*"; }
die() { printf '%sinstall.sh: %s%s\n' "$RED" "$*" "$NC" >&2; exit 1; }

# --- This Mac ----------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || die "Galaxy runs on macOS only."
[[ "$(uname -m)" == "arm64" ]] || die "Galaxy releases are built for Apple Silicon (arm64) only."
macos="$(sw_vers -productVersion)"
(( ${macos%%.*} >= MIN_MACOS )) || die "Galaxy needs macOS $MIN_MACOS or later; this Mac runs $macos."

work="$(mktemp -d)"
installed_ok=false
gx_cleanup() {
  if $installed_ok || $preview; then rm -rf "${work:?}"
  else printf 'Working files kept for inspection: %s\n' "$work" >&2; fi
}
trap gx_cleanup EXIT

# --- Fetch -------------------------------------------------------------------

if [[ -n "$from" ]]; then
  [[ -f "$from" ]] || die "no archive at $from"
  cp "$from" "$work/$ASSET"
  if [[ -f "$from.sha256" ]]; then
    cp "$from.sha256" "$work/$ASSET.sha256"
  fi
  source_label="$from"
else
  if [[ -n "$version" ]]; then
    base="https://github.com/$REPO/releases/download/v$version"
  else
    base="https://github.com/$REPO/releases/latest/download"
  fi
  # curl rather than a browser download: curl sets no quarantine flag, which
  # is what lets a self-signed Galaxy.app open without a Gatekeeper prompt.
  curl -fsSL "$base/$ASSET" -o "$work/$ASSET" \
    || die "could not download $base/$ASSET${version:+ (is v$version a Galaxy release?)}"
  curl -fsSL "$base/$ASSET.sha256" -o "$work/$ASSET.sha256" \
    || die "could not download the checksum for $ASSET"
  source_label="$base"
fi

if [[ -f "$work/$ASSET.sha256" ]]; then
  (cd "$work" && shasum -a 256 -c "$ASSET.sha256" >/dev/null) \
    || die "checksum mismatch for $ASSET; nothing was installed"
elif [[ -z "$from" ]]; then
  die "no checksum for $ASSET; nothing was installed"
fi

tar -xzf "$work/$ASSET" -C "$work" || die "could not unpack $ASSET"
pkg="$work/galaxy"
[[ -f "$pkg/manifest.json" && -d "$pkg/bin" && -d "$pkg/Galaxy.app" ]] \
  || die "$ASSET is not a Galaxy release archive"

manifest_field() { sed -n "s/^  \"$1\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$2" | head -1; }
new_version="$(manifest_field version "$pkg/manifest.json")"
new_commit="$(manifest_field commit "$pkg/manifest.json")"
new_dirty="$(manifest_field dirty "$pkg/manifest.json")"
if [[ -f "$INSTALLED_MANIFEST" ]]; then
  cur_version="$(manifest_field version "$INSTALLED_MANIFEST")"
  cur_commit="$(manifest_field commit "$INSTALLED_MANIFEST")"
  cur_dirty="$(manifest_field dirty "$INSTALLED_MANIFEST")"
elif [[ -x "$BIN_DIR/galaxy" ]]; then
  cur_version="unknown (installed from source)"; cur_commit=""; cur_dirty=""
else
  cur_version="not installed"; cur_commit=""; cur_dirty=""
fi
first_install=false
[[ -e "$APP" || -L "$APP" ]] || first_install=true

describe() { printf '%s' "$1"; [[ -n "$2" ]] && printf ' (%s%s)' "$2" "$([[ "$3" == true ]] && echo ', uncommitted changes')"; }

# A release is up to date when it is the same commit with no local edits.
# --from always installs, because a local archive is installed on purpose.
if [[ -z "$from" ]] && ! $force && ! $preview \
   && [[ "$cur_commit" == "$new_commit" && "$cur_dirty" != "true" ]]; then
  say "${GREEN}Galaxy is up to date: $(describe "$cur_version" "$cur_commit" "$cur_dirty")${NC}"
  installed_ok=true
  exit 0
fi

say "${BOLD}$([[ "$cur_version" == "not installed" ]] && echo Installing || echo Updating) Galaxy${NC}"
step "From:      $source_label"
step "Installed: $(describe "$cur_version" "$cur_commit" "$cur_dirty")"
step "New:       $(describe "$new_version" "$new_commit" "$new_dirty")"
step "Tools:     $BIN_DIR (linked into $LOCAL_BIN)"
step "App:       $APP"
signer="$(codesign -dv --verbose=2 "$pkg/Galaxy.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[[ -n "$signer" ]] || signer="ad-hoc (macOS will ask for Galaxy's permissions again)"
step "Signed by: $signer"

if $preview; then
  say ""
  say "Preview only: nothing was changed. Run without --preview to install."
  exit 0
fi
say ""

# --- Install -----------------------------------------------------------------

mkdir -p "$BIN_DIR" "$LOCAL_BIN" "$APP_DIR"

for src in "$pkg"/bin/*; do
  name="$(basename "$src")"
  # A new file moved over the old one, rather than copied onto it, so a
  # binary that is running keeps its pages and macOS sees a fresh signature.
  install -m 755 "$src" "$BIN_DIR/.$name.new"
  mv -f "$BIN_DIR/.$name.new" "$BIN_DIR/$name"
  ln -sfn "$BIN_DIR/$name" "$LOCAL_BIN/$name"
done
step "Installed $(find "$pkg/bin" -type f | wc -l | tr -d ' ') tools"

# Swapped by rename: a running Galaxy keeps running from its old bundle, and
# the next launch opens the new one.
rm -rf "${APP:?}.new" "${APP:?}.old"
ditto "$pkg/Galaxy.app" "$APP.new"
if [[ -L "$APP" ]]; then
  rm "$APP"
elif [[ -e "$APP" ]]; then
  mv "$APP" "$APP.old"
fi
mv "$APP.new" "$APP"
rm -rf "${APP:?}.old"
step "Installed Galaxy.app"

if $register; then
  "$LSREGISTER" -f "$APP"
  # Copies left in an Xcode build folder share the bundle id, and Launch
  # Services can hand galaxy:// links to whichever copy it prefers.
  while IFS= read -r stale; do
    "$LSREGISTER" -u "$stale" 2>/dev/null || true
    step "Unregistered $stale"
  done < <("$LSREGISTER" -dump 2>/dev/null \
             | sed -n 's/^path: *\(.*\/Build\/Products\/[^/]*\/Galaxy\.app\) (0x[0-9a-f]*)$/\1/p' \
             | sort -u)
fi

for t in "${SETUP_TOOLS[@]}"; do
  bin="$BIN_DIR/galaxy-$t"
  [[ -x "$bin" ]] || continue
  "$bin" install >/dev/null || die "galaxy-$t install failed; run it by hand to see why"
done
step "Set up skills and hooks"

cp "$pkg/manifest.json" "$INSTALLED_MANIFEST"
installed_ok=true

# --- Next steps --------------------------------------------------------------

say ""
say "${GREEN}Galaxy $(describe "$new_version" "$new_commit" "$new_dirty") is installed.${NC}"
case ":$PATH:" in
  *":$LOCAL_BIN:"*) ;;
  *) say "Add $LOCAL_BIN to your PATH to use the galaxy commands." ;;
esac
if $first_install; then
  say "Open Galaxy with: open \"$APP\""
else
  say "Restart Galaxy when you're ready to switch to the new version."
fi
