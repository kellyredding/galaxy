#!/usr/bin/env bash
#
# check-disclosure.sh — refuse to ship employer- or deployment-specific details.
#
# This repository is public. It is a personal toolkit, so it may name its own
# author and its own paths freely — but it must not name an employer, their
# repositories, their infrastructure, or anyone's credentials. Those arrive in
# example output and spec fixtures almost by accident, because the easiest
# example to write is whatever was on screen at the time.
#
# Ported from the sibling `conduit` repository, which needs a stricter version
# of the same idea. Two layers, because they fail differently:
#
#   1. STRUCTURAL patterns, defined here. These describe the *shape* of a
#      leak — a dotted quad, a cloud account identifier — so they catch new
#      leaks nobody thought to add to a list, and they can live in a public
#      repository because they name nothing.
#
#   2. A LITERAL denylist, deliberately NOT in this repository. It holds the
#      exact strings that must never appear here, which is precisely why
#      committing it would be the leak it exists to prevent. It is optional:
#      absent means the structural layer runs alone.
#
#        $GALAXY_DENYLIST, else ~/.claude/galaxy/denylist.txt, else ./denylist.txt
#
#      One extended-regex pattern per line; blank lines and #-comments are
#      ignored. Matching is case-insensitive. Share one file across every
#      public repository rather than keeping copies that drift.
#
# WHY THIS IS LOOSER THAN CONDUIT'S
#
# Conduit must never describe anyone's particular VPN, so it refuses paths and
# addresses outright. Galaxy legitimately documents paths, renders example
# status lines, and ships spec fixtures full of directories — placeholders are
# the fix there, not prohibition. So this checks for the classes that are never
# legitimate here, and leaves ordinary paths alone.
#
# Scans git-tracked files only, so build output and scratch files are out of
# scope. Binary files are skipped by ripgrep. Exit 1 on any match.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SELF="scripts/check-disclosure.sh"
found=0

# Report matches for one rule. Non-fatal individually so a single run
# surfaces every problem rather than only the first.
scan() {
  local label="$1" pattern="$2"
  shift 2

  local hits
  hits=$(git ls-files -z \
    | xargs -0 rg --no-messages --with-filename --line-number \
        --ignore-case --regexp "$pattern" -- 2>/dev/null \
    | rg -v "^$SELF:" || true)

  # Apply per-rule allowances (well-known non-identifying values).
  local allow
  for allow in "$@"; do
    hits=$(printf '%s\n' "$hits" | rg -v -F "$allow" || true)
  done

  [ -z "$hits" ] && return 0
  found=1
  printf '\n  %s\n' "$label"
  printf '%s\n' "$hits" | sed 's/^/    /'
}

echo "disclosure audit"

# A dotted quad is almost never legitimate here. Loopback, the unspecified
# address, and the broadcast address are the exceptions.
#
# Delimited rather than \b-anchored, which matters more here than in conduit:
# inline SVG icon path data is full of coordinate runs like ".138.112.25.25"
# that are shape-identical to an address. Requiring the match to start after
# whitespace, a quote, or an opening bracket removes ten such false positives
# while still catching a real address — both directions verified.
#
# ArtifactDiffView.swift is allowed for this rule alone. It carries the inline
# SVG for the diff viewer's icons, one run of which ("1.23.82.72") is a valid
# dotted quad by shape and cannot be distinguished by pattern. The file has no
# network surface at all, so the coverage given up is nil.
scan "network address literal" \
  '(^|[[:space:]"'"'"'=(,])[0-9]{1,3}(\.[0-9]{1,3}){3}($|[[:space:]"'"'"')/,;])' \
  '0.0.0.0' '127.0.0.1' '255.255.255.255' 'ArtifactDiffView.swift'

scan "routed range (CIDR)" \
  '\b[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}\b'

# The author's own address is intentional in package metadata. Obvious
# throwaways are how a spec says "an address, any address".
scan "email address" \
  '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' \
  'kellyredding.com' 'git@github.com' 'git@gitlab.com' \
  'example.com' 'test@test.com' 't@t.com' '@2x.png'

# Delimited for the same reason, and a different false positive: the last
# segment of a UUID is twelve hex characters, so an all-digit one reads as an
# account identifier. Excluding a leading hyphen removes those without losing a
# standalone identifier — again verified both ways.
scan "cloud account identifier" \
  '(^|[[:space:]"'"'"'=(,:])[0-9]{12}($|[[:space:]"'"'"'),;])'
scan "cloud resource name"      'arn:[a-z-]*:'
scan "internal hostname"        '\.(internal|corp|intranet)\b'

# Credentials, which are never a placeholder worth keeping.
scan "private key block"        'BEGIN [A-Z ]*PRIVATE KEY'
scan "bearer or api token"      '\b(sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{20,}|xox[baprs]-[a-zA-Z0-9-]{10,})'

# Layer 2: the literal list, kept outside the repository.
DENYLIST="${GALAXY_DENYLIST:-}"
if [ -z "$DENYLIST" ]; then
  if [ -f "$HOME/.claude/galaxy/denylist.txt" ]; then
    DENYLIST="$HOME/.claude/galaxy/denylist.txt"
  elif [ -f "denylist.txt" ]; then
    DENYLIST="denylist.txt"
  fi
fi

if [ -n "$DENYLIST" ] && [ -f "$DENYLIST" ]; then
  # `rg --file` takes every line as a pattern — it has no notion of comments,
  # and a blank line is a pattern matching everything. Strip both before
  # handing the file over, or the denylist reports the entire repository.
  compiled=$(mktemp)
  trap 'rm -f "$compiled"' EXIT
  rg -v '^[[:space:]]*(#|$)' "$DENYLIST" > "$compiled" || true

  if [ -s "$compiled" ]; then
    hits=$(git ls-files -z \
      | xargs -0 rg --no-messages --with-filename --line-number \
          --ignore-case --file "$compiled" -- 2>/dev/null \
      | rg -v "^$SELF:" || true)
  else
    hits=""
  fi

  if [ -n "$hits" ]; then
    found=1
    printf '\n  denylisted term\n'
    printf '%s\n' "$hits" | sed 's/^/    /'
  fi
  echo "  denylist: $DENYLIST"
else
  # Refusing here rather than warning. A guard that quietly covers less than
  # it claims is worse than no guard: the structural layer alone would still
  # print "clean" and let the commit through, so a machine that was never set
  # up would silently lose the literal layer with no signal at all.
  cat <<'EOF'

FAILED — no literal denylist found.

The structural checks ran, but the terms that must never appear verbatim live
outside this repository and none was located. Looked for, in order:
  $GALAXY_DENYLIST, ~/.claude/galaxy/denylist.txt, ./denylist.txt

On a configured machine the file is a symlink into the sync tree, shared with
the other public repositories rather than copied per repo. To restore:
  ln -s ~/Sync/<user>/conduit/denylist.txt ~/.claude/galaxy/denylist.txt

Working on a clone with no such list, and accepting structural checks alone:
  GALAXY_ALLOW_NO_DENYLIST=1 make audit
EOF
  [ "${GALAXY_ALLOW_NO_DENYLIST:-}" = "1" ] || exit 1
  echo
  echo "  denylist: none — proceeding on GALAXY_ALLOW_NO_DENYLIST"
fi

if [ "$found" -ne 0 ]; then
  cat <<'EOF'

FAILED — the matches above look employer- or deployment-specific.

This repository is public. Example output and spec fixtures should use
placeholders, not whatever was on screen when they were written:
  a project directory  →  ~/projects/my-app
  an org and repo      →  ~/projects/acme/acme-products
If a match is a false positive, add a narrow allowance in scripts/check-disclosure.sh
and say in the commit why it is safe.
EOF
  exit 1
fi

echo "  clean"
