#!/bin/bash
#
# Setup script for GalaxyPOC vendored dependencies
#
# This script clones SwiftTerm v1.10.1 and applies a patch to fix
# Swift Package Manager compatibility issues (trailing commas in
# function arguments are a Swift 5.9+ feature, but SPM compiles
# Package.swift manifests with -swift-version 5).
#
# Usage: ./scripts/setup-vendor.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PROJECT_DIR/Vendor"
SWIFTTERM_VERSION="v1.10.1"

echo "==> Setting up vendored dependencies for GalaxyPOC"
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

# Apply patch to fix SPM compatibility
echo "==> Applying SPM compatibility patch..."
PACKAGE_SWIFT="$VENDOR_DIR/SwiftTerm/Package.swift"

if grep -q 'exclude: platformExcludes + \["Mac/README.md"\],' "$PACKAGE_SWIFT" 2>/dev/null; then
    echo "    Removing trailing commas from function arguments..."

    # macOS sed requires different syntax
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Fix trailing commas in function argument lists (Swift 5.9+ feature not supported by SPM)
        sed -i '' 's/exclude: platformExcludes + \["Mac\/README.md"\],/exclude: platformExcludes + ["Mac\/README.md"]/g' "$PACKAGE_SWIFT"
        # Remove spaces before ( in .executableTarget
        sed -i '' 's/\.executableTarget (/.executableTarget(/g' "$PACKAGE_SWIFT"
        # Remove commented-out code blocks that might cause issues
        sed -i '' '/\/\/.*dependencies:/d' "$PACKAGE_SWIFT"
        sed -i '' '/\/\/.*\.product(name: "Subprocess"/d' "$PACKAGE_SWIFT"
        sed -i '' '/\/\/.*swiftSettings:/d' "$PACKAGE_SWIFT"
        sed -i '' '/\/\/.*\.unsafeFlags/d' "$PACKAGE_SWIFT"
        sed -i '' '/\/\/[[:space:]]*\]/d' "$PACKAGE_SWIFT"
        sed -i '' '/\/\/[[:space:]]*We can not use Swift Subprocess/d' "$PACKAGE_SWIFT"
        sed -i '' '/\/\/[[:space:]]*be a controlling terminal/d' "$PACKAGE_SWIFT"
    else
        # Linux sed
        sed -i 's/exclude: platformExcludes + \["Mac\/README.md"\],/exclude: platformExcludes + ["Mac\/README.md"]/g' "$PACKAGE_SWIFT"
        sed -i 's/\.executableTarget (/.executableTarget(/g' "$PACKAGE_SWIFT"
    fi

    echo "    Patch applied successfully"
else
    echo "    Package.swift already patched or structure changed"
fi

echo ""
echo "==> Setup complete!"
echo ""
echo "Next steps:"
echo "  1. cd $PROJECT_DIR"
echo "  2. xcodegen generate"
echo "  3. xcodebuild -project GalaxyPOC.xcodeproj -scheme GalaxyPOC build"
echo ""
