#!/usr/bin/env bash
#
# galaxy update script
# https://github.com/kellyredding/galaxy
#
# This script is fetched and executed by `galaxy update`.
# It can be modified without releasing new CLI versions.
#
set -euo pipefail

# Configuration
REPO="kellyredding/galaxy"
TOOL_NAME="galaxy"
BINARY_NAME="galaxy"
TAG_PREFIX="${TOOL_NAME}-v"
INSTALL_DIR="${HOME}/.claude/galaxy/bin"
INSTALL_PATH="${INSTALL_DIR}/${BINARY_NAME}"
BACKUP_DIR="${HOME}/.claude/galaxy/galaxy/update-backup"
GITHUB_API="https://api.github.com/repos/${REPO}/releases"
GITHUB_RELEASES="https://github.com/${REPO}/releases/download"

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  NC='\033[0m' # No Color
else
  RED=''
  GREEN=''
  YELLOW=''
  CYAN=''
  NC=''
fi

# Parse arguments
PREVIEW=false
FORCE=false

show_help() {
  cat <<EOF
galaxy update - Update to the latest version

Usage:
  galaxy update           Update to latest version
  galaxy update preview   Preview update without making changes
  galaxy update force     Reinstall latest (even if up-to-date)
  galaxy update help      Show this help

The update downloads the latest release from GitHub, verifies the
checksum, and replaces the current binary.

Update script: https://raw.githubusercontent.com/${REPO}/main/tools/galaxy/scripts/update.sh
EOF
}

for arg in "$@"; do
  case $arg in
    preview) PREVIEW=true ;;
    force) FORCE=true ;;
    help) show_help; exit 0 ;;
  esac
done

# Detect platform
detect_platform() {
  local os arch

  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)

  case "$os" in
    darwin) os="darwin" ;;
    linux) os="linux" ;;
    *)
      echo -e "${RED}Unsupported OS: $os${NC}" >&2
      exit 1
      ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      echo -e "${RED}Unsupported architecture: $arch${NC}" >&2
      exit 1
      ;;
  esac

  echo "${os}-${arch}"
}

# Check write permissions
check_permissions() {
  local path="$1"
  local dir
  dir=$(dirname "$path")

  if [[ -w "$path" ]] || [[ -w "$dir" ]]; then
    return 0
  else
    return 1
  fi
}

# Restore from backup (remove first to avoid macOS code signing issues)
restore_backup() {
  local target="$1"
  rm -f "$target"
  cp "${BACKUP_DIR}/${BINARY_NAME}.backup" "$target"
  chmod +x "$target"
}

# Main update logic
main() {
  # Use fixed install location
  local install_path="$INSTALL_PATH"

  # Get current version (or "not installed" if binary doesn't exist)
  local current_version
  if [[ -f "$install_path" ]]; then
    current_version=$("$install_path" version 2>/dev/null || echo "unknown")
  else
    current_version="not installed"
  fi

  # Fetch releases from GitHub API and find latest for this tool
  # Uses grep/sed instead of jq to avoid external dependencies
  local api_response latest_tag latest_version
  api_response=$(curl -sS "$GITHUB_API" 2>/dev/null) || {
    echo -e "${RED}Failed to fetch release information from GitHub${NC}" >&2
    exit 1
  }

  # Find the first (newest) release with our tool prefix
  latest_tag=$(echo "$api_response" | grep '"tag_name":' | grep "$TAG_PREFIX" | head -1 | sed 's/.*"tag_name": *"//;s/".*//')

  if [[ -z "$latest_tag" ]]; then
    echo -e "${RED}No releases found for ${TOOL_NAME}${NC}" >&2
    exit 1
  fi

  # Extract version from tag (strip prefix)
  latest_version="${latest_tag#${TAG_PREFIX}}"

  # Detect platform
  local platform
  platform=$(detect_platform)

  # Check if update is needed (skip for preview and force modes)
  # Always proceed if not installed
  if [[ "$current_version" != "not installed" ]] && [[ "$current_version" == "$latest_version" ]] && [[ "$FORCE" != true ]] && [[ "$PREVIEW" != true ]]; then
    echo -e "${GREEN}Already up to date (v${current_version})${NC}"
    exit 0
  fi

  # Build artifact names
  local tarball_name="${BINARY_NAME}-${latest_version}-${platform}.tar.gz"
  local checksum_name="${BINARY_NAME}-${latest_version}-${platform}.tar.gz.sha256"
  local download_url="${GITHUB_RELEASES}/${latest_tag}/${tarball_name}"
  local checksum_url="${GITHUB_RELEASES}/${latest_tag}/${checksum_name}"
  local script_url="https://raw.githubusercontent.com/${REPO}/main/tools/galaxy/scripts/update.sh"

  # Preview mode - show what would happen and exit
  if [[ "$PREVIEW" == true ]]; then
    echo -e "${CYAN}Update Preview${NC}"
    echo ""
    echo "  Current version:  ${current_version}"
    echo "  Latest version:   ${latest_version}"
    echo "  Install location: ${install_path}"
    echo "  Platform:         ${platform}"
    echo ""
    echo "  Update script: ${script_url}"
    echo ""
    if [[ "$current_version" == "$latest_version" ]]; then
      echo -e "  ${GREEN}Already up to date${NC} - no action needed."
      echo ""
      echo "  To force reinstall, run:"
      echo "    galaxy update force"
    else
      echo "  Actions that would be performed:"
      echo "    1. Download ${tarball_name}"
      echo "    2. Verify SHA256 checksum"
      echo "    3. Backup current binary"
      echo "    4. Install new binary"
      echo ""
      echo "  To perform the update, run:"
      echo "    galaxy update"
    fi
    exit 0
  fi

  # Ensure install directory exists
  mkdir -p "$INSTALL_DIR"

  # Check write permissions before starting
  if ! check_permissions "$install_path"; then
    echo -e "${RED}Update failed${NC}" >&2
    echo "" >&2
    echo "  Install location requires elevated permissions:" >&2
    echo "    ${install_path}" >&2
    echo "" >&2
    echo "  Run with sudo:" >&2
    echo "    sudo galaxy update" >&2
    exit 1
  fi

  # Perform update
  local action_word="Updating"
  if [[ "$current_version" == "not installed" ]]; then
    action_word="Installing"
  elif [[ "$FORCE" == true ]] && [[ "$current_version" == "$latest_version" ]]; then
    action_word="Reinstalling"
  fi

  echo -e "${CYAN}${action_word} galaxy${NC}"
  echo ""
  echo "  Current version:  ${current_version}"
  if [[ "$action_word" == "Reinstalling" ]]; then
    echo "  Latest version:   ${latest_version} (reinstalling)"
  else
    echo "  Latest version:   ${latest_version}"
  fi
  echo "  Install location: ${install_path}"
  echo "  Platform:         ${platform}"
  echo ""

  # Create temp directory (script-level for trap access)
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  # Step 1: Download tarball
  echo -n "  [1/4] Downloading ${tarball_name}... "
  if ! curl -fsSL "$download_url" -o "${TMP_DIR}/${tarball_name}" 2>/dev/null; then
    echo -e "${RED}failed${NC}"
    echo "" >&2
    echo "  Could not download: ${download_url}" >&2
    exit 1
  fi
  echo -e "${GREEN}done${NC}"

  # Step 2: Verify checksum
  echo -n "  [2/4] Verifying checksum... "
  local expected_checksum
  expected_checksum=$(curl -fsSL "$checksum_url" 2>/dev/null | awk '{print $1}')

  if [[ -z "$expected_checksum" ]]; then
    echo -e "${RED}failed${NC}"
    echo "" >&2
    echo "  Could not fetch checksum: ${checksum_url}" >&2
    exit 1
  fi

  local actual_checksum
  if command -v sha256sum &>/dev/null; then
    actual_checksum=$(sha256sum "${TMP_DIR}/${tarball_name}" | awk '{print $1}')
  elif command -v shasum &>/dev/null; then
    actual_checksum=$(shasum -a 256 "${TMP_DIR}/${tarball_name}" | awk '{print $1}')
  else
    echo -e "${RED}failed${NC}"
    echo "" >&2
    echo "  No sha256sum or shasum available" >&2
    exit 1
  fi

  if [[ "$expected_checksum" != "$actual_checksum" ]]; then
    echo -e "${RED}failed${NC}"
    echo "" >&2
    echo "  Checksum mismatch!" >&2
    echo "  Expected: ${expected_checksum}" >&2
    echo "  Actual:   ${actual_checksum}" >&2
    exit 1
  fi
  echo -e "${GREEN}done${NC}"

  # Step 3: Backup current binary (skip if fresh install)
  if [[ -f "$install_path" ]]; then
    echo -n "  [3/4] Backing up current binary... "
    mkdir -p "$BACKUP_DIR"
    if ! cp "$install_path" "${BACKUP_DIR}/${BINARY_NAME}.backup"; then
      echo -e "${RED}failed${NC}"
      echo "" >&2
      echo "  Could not backup: ${install_path}" >&2
      exit 1
    fi
    echo -e "${GREEN}done${NC}"
  else
    echo "  [3/4] Backing up current binary... skipped (fresh install)"
  fi

  # Step 4: Extract and install
  echo -n "  [4/4] Installing new binary... "

  # Extract to temp dir
  if ! tar -xzf "${TMP_DIR}/${tarball_name}" -C "$TMP_DIR" 2>/dev/null; then
    echo -e "${RED}failed${NC}"
    echo "" >&2
    echo "  Could not extract tarball" >&2
    # Restore backup
    restore_backup "$install_path"
    exit 1
  fi

  # Find the binary in extracted contents
  # Binary is named galaxy-{version}-{platform} in the tarball
  local new_binary="${TMP_DIR}/${BINARY_NAME}-${latest_version}-${platform}"
  if [[ ! -f "$new_binary" ]]; then
    # Fallback: try just the binary name
    new_binary="${TMP_DIR}/${BINARY_NAME}"
  fi
  if [[ ! -f "$new_binary" ]]; then
    # Fallback: search for it
    new_binary=$(find "$TMP_DIR" -name "${BINARY_NAME}*" -type f | head -1)
  fi

  if [[ -z "$new_binary" ]] || [[ ! -f "$new_binary" ]]; then
    echo -e "${RED}failed${NC}"
    echo "" >&2
    echo "  Binary not found in tarball" >&2
    # Restore backup
    restore_backup "$install_path"
    exit 1
  fi

  # Remove existing binary first to avoid macOS code signing issues,
  # then move new binary into place (mv is atomic on same filesystem)
  chmod +x "$new_binary"
  rm -f "$install_path"
  if ! mv "$new_binary" "$install_path"; then
    echo -e "${RED}failed${NC}"
    echo "" >&2
    echo "  Could not install new binary" >&2
    # Restore backup
    restore_backup "$install_path"
    exit 1
  fi
  echo -e "${GREEN}done${NC}"

  # Verify installation
  local installed_version
  installed_version=$("$install_path" version 2>/dev/null || echo "unknown")

  if [[ "$installed_version" != "$latest_version" ]]; then
    echo "" >&2
    echo -e "${YELLOW}Warning: Installed version (${installed_version}) doesn't match expected (${latest_version})${NC}" >&2
  fi

  # Clean up backup on success
  rm -f "${BACKUP_DIR}/${BINARY_NAME}.backup"

  echo ""
  echo -e "${GREEN}Updated to v${latest_version}${NC}"
  echo ""
  echo "  Verify: galaxy version"
}

main "$@"
