# shellcheck shell=bash
# Sourced by bin/package and bin/release: what a release runs on, and the check
# that a staged or unpacked galaxy/ folder really does.
#
# The floor also lives in tools/build.mk, GalaxyApp/project.yml and install.sh;
# this check is what fails when one of them moves without the others.
GALAXY_ARCHS="arm64 x86_64"
GALAXY_MIN_MACOS="15.0"

# Prints the first problem and returns 1, or returns 0. Needs Xcode's tools,
# which only the building Mac has; install.sh relies on the manifest instead.
gx_check_universal() {
  local dir="$1" app="$1/Galaxy.app" exe name libs outside arch minos f plist_min
  for exe in "$dir"/bin/* "$app/Contents/MacOS/Galaxy"; do
    name="${exe#"$dir"/}"
    libs="$(otool -arch all -L "$exe" 2>&1)" || { echo "$name: otool cannot read it"; return 1; }
    outside="$(printf '%s\n' "$libs" | awk '/^\t/{print $1}' \
                 | grep -vE '^(/usr/lib/|/System/Library/)' | sort -u || true)"
    if [[ -n "$outside" ]]; then
      echo "$name loads libraries from outside the system: $(printf '%s' "$outside" | tr '\n' ' ')"
      return 1
    fi
    # One architecture per call: `lipo FILE -verify_arch arm64 x86_64` refuses
    # even a good universal file.
    for arch in $GALAXY_ARCHS; do
      lipo "$exe" -verify_arch "$arch" 2>/dev/null || { echo "$name has no $arch code"; return 1; }
      minos="$(vtool -arch "$arch" -show-build "$exe" 2>/dev/null | awk '/minos/{print $2; exit}')"
      if [[ "$minos" != "$GALAXY_MIN_MACOS" ]]; then
        echo "$name ($arch) is built for macOS ${minos:-unknown}, not $GALAXY_MIN_MACOS"
        return 1
      fi
    done
  done

  # The packages are linked statically. A framework or a second Mach-O means
  # one went dynamic, and the loop above never looked at it.
  if [[ -e "$app/Contents/Frameworks" ]]; then
    echo "Galaxy.app has a Contents/Frameworks folder"
    return 1
  fi
  while IFS= read -r f; do
    [[ "$f" == "$app/Contents/MacOS/Galaxy" ]] && continue
    if [[ "$(file -b "$f")" == Mach-O* ]]; then
      echo "Galaxy.app holds an unchecked Mach-O: ${f#"$app"/}"
      return 1
    fi
  done < <(find "$app" -type f)

  plist_min="$(plutil -extract LSMinimumSystemVersion raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$plist_min" != "$GALAXY_MIN_MACOS" ]]; then
    echo "Galaxy.app's LSMinimumSystemVersion is ${plist_min:-missing}, not $GALAXY_MIN_MACOS"
    return 1
  fi
}
