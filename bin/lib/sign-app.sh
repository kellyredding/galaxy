#!/usr/bin/env bash
# Usage: sign-app.sh (op|adhoc) <bundle>
#
# op:    signs with the release identity, fetched from 1Password into a
#        throwaway keychain that is deleted on exit. The login keychain is
#        never used: a key there needs the user's login password, which
#        surfaces as a dialog mid-build.
# adhoc: signs with no identity. Works anywhere, but macOS treats every
#        ad-hoc build as a new app and asks for its privacy permissions again.
set -euo pipefail

mode="${1:?usage: sign-app.sh (op|adhoc) <bundle>}"
bundle="${2:?usage: sign-app.sh (op|adhoc) <bundle>}"

OP_ACCOUNT="${GALAXY_SIGNING_OP_ACCOUNT:-my.1password.com}"
OP_ITEM="${GALAXY_SIGNING_OP_ITEM:-op://Private/Galaxy Release Signing}"

if [[ "$mode" == "adhoc" ]]; then
  codesign --force --sign - --timestamp=none "$bundle"
  exit 0
fi
[[ "$mode" == "op" ]] || { echo "sign-app.sh: unknown mode '$mode'" >&2; exit 2; }

work="$(mktemp -d)"
kc="$work/galaxy-signing.keychain-db"
kcpass="$(/usr/bin/openssl rand -hex 24)"

orig_list=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [[ -n "$line" ]] && orig_list+=("$line")
done < <(security list-keychains -d user)

gx_cleanup() {
  security list-keychains -d user -s "${orig_list[@]}" || true
  security delete-keychain "$kc" 2>/dev/null || true
  rm -rf "${work:?}"
}
trap gx_cleanup EXIT

# op gives up on the desktop app within a few seconds, often while its
# approval prompt is still on screen, so retry until the approval lands.
for attempt in $(seq 1 40); do
  if op read --account "$OP_ACCOUNT" --out-file "$work/signing.p12" --force "$OP_ITEM/signing.p12" >/dev/null 2>&1; then
    break
  fi
  if (( attempt == 1 )); then
    echo "Approve the 1Password prompt to sign Galaxy.app..." >&2
  fi
  if (( attempt == 40 )); then
    echo "1Password never provided the signing identity. To build without it: bin/package --local --sign adhoc" >&2
    exit 1
  fi
  sleep 3
done
p12pass="$(op read --account "$OP_ACCOUNT" "$OP_ITEM/password")"
identity="$(op read --account "$OP_ACCOUNT" "$OP_ITEM/sha1")"

security create-keychain -p "$kcpass" "$kc"
# No auto-lock and no lock on sleep: a keychain that locks mid-run raises a
# password dialog for a password no one knows.
security set-keychain-settings "$kc"
security unlock-keychain -p "$kcpass" "$kc"
security import "$work/signing.p12" -k "$kc" -P "$p12pass" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpass" "$kc" >/dev/null
# codesign --keychain only searches keychains already on the search list.
security list-keychains -d user -s "${orig_list[@]}" "$kc"

codesign --force --keychain "$kc" --sign "$identity" --timestamp=none "$bundle"
