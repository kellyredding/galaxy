#!/bin/bash
#
# Setup script for GalaxyApp vendored dependencies
#
# This script clones SwiftTerm v1.10.1 and applies the Galaxy
# customization patch. The patch covers both Galaxy's rendering
# changes (FillStroke thickening, bold brightening, block element
# boundary fix) and SPM compatibility tweaks to Package.swift
# (trailing commas, executable-target spacing — Swift 5.9+
# parser-tolerant syntax that SPM's older parser rejects).
#
# Usage: ./scripts/setup-vendor.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PROJECT_DIR/Vendor"
SWIFTTERM_VERSION="v1.10.1"

echo "==> Setting up vendored dependencies for GalaxyApp"
echo "    Project: $PROJECT_DIR"
echo "    Vendor:  $VENDOR_DIR"

# Create Vendor directory if needed
mkdir -p "$VENDOR_DIR"

# Clone SwiftTerm if not present
if [ -d "$VENDOR_DIR/SwiftTerm" ]; then
    echo "==> SwiftTerm already exists, checking version..."
    cd "$VENDOR_DIR/SwiftTerm"
    CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "unknown")
    if [ "$CURRENT_TAG" = "$SWIFTTERM_VERSION" ]; then
        echo "    SwiftTerm $SWIFTTERM_VERSION already set up"
    else
        echo "    WARNING: SwiftTerm is at $CURRENT_TAG, expected $SWIFTTERM_VERSION"
        echo "    Remove Vendor/SwiftTerm and re-run this script to update"
    fi
else
    echo "==> Cloning SwiftTerm $SWIFTTERM_VERSION..."
    cd "$VENDOR_DIR"
    git clone --depth 1 --branch "$SWIFTTERM_VERSION" https://github.com/migueldeicaza/SwiftTerm.git
    echo "    Cloned successfully"
fi

# Apply Galaxy customization patch. Touches Package.swift (SPM
# compatibility tweaks) plus 9 Sources/SwiftTerm/*.swift files (font
# rendering: FillStroke thickening, bold brightening, block element
# boundary fix). Single source of truth for all Galaxy-side changes
# to the vendored SwiftTerm checkout.
RENDERING_PATCH="$SCRIPT_DIR/galaxy-swiftterm-rendering.patch"
if [ -f "$RENDERING_PATCH" ]; then
    echo "==> Checking Galaxy font rendering patch..."
    cd "$VENDOR_DIR/SwiftTerm"
    if git apply --reverse --check "$RENDERING_PATCH" 2>/dev/null; then
        echo "    Rendering patch already applied"
    elif git apply --check "$RENDERING_PATCH" 2>/dev/null; then
        echo "==> Applying Galaxy font rendering patch..."
        git apply "$RENDERING_PATCH"
        echo "    Rendering patch applied successfully"
    else
        echo "    ERROR: rendering patch cannot be applied cleanly"
        echo "    SwiftTerm at: $(git describe --tags --exact-match 2>/dev/null || echo unknown)"
        echo "    Patch:        $RENDERING_PATCH"
        echo "    To investigate: cd $VENDOR_DIR/SwiftTerm && git apply -v $RENDERING_PATCH"
        exit 1
    fi
fi

echo ""
echo "==> Setup complete!"
echo ""
echo "Next steps:"
echo "  1. cd $PROJECT_DIR"
echo "  2. xcodegen generate"
echo "  3. xcodebuild -project GalaxyApp.xcodeproj -scheme GalaxyApp build"
echo ""
