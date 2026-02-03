# GalaxyPOC Setup Guide

This document explains how to set up the GalaxyPOC project for building, including vendored dependencies.

## Prerequisites

- **Xcode 16.2+** (with Swift 6.0+)
- **XcodeGen** (`brew install xcodegen`)
- **Git**

## Quick Start

```bash
cd GalaxyPOC

# 1. Set up vendored dependencies (SwiftTerm)
./scripts/setup-vendor.sh

# 2. Generate Xcode project
xcodegen generate

# 3. Build
xcodebuild -project GalaxyPOC.xcodeproj -scheme GalaxyPOC -configuration Debug build
```

## Vendored Dependencies

### Why Vendor SwiftTerm?

SwiftTerm v1.10.1 uses Swift 5.9+ syntax features (trailing commas in function arguments) in its `Package.swift`. However, Swift Package Manager compiles package manifests with `-swift-version 5`, which doesn't support this syntax.

Rather than:
- Pinning to an older version (missing emoji fixes, performance improvements)
- Maintaining a GitHub fork

We vendor SwiftTerm locally and apply a minimal patch.

### SwiftTerm v1.10.1

**Location:** `Vendor/SwiftTerm/`

**Patch applied:** Remove trailing commas from function argument lists in `Package.swift`

**Features gained over v1.2.5:**
| Feature | Version | Impact |
|---------|---------|--------|
| Emoji/Unicode positioning fixes | 1.6.0, 1.8.0 | Claude uses emoji in output |
| 58% performance improvement | 1.9.0 | Smoother terminal rendering |
| Thread-safety improvements | 1.8.0 | Better multi-session handling |
| Dim/faint text (SGR 2) | 1.10.0 | Visual polish |

### Manual Setup (Alternative)

If the setup script doesn't work, you can set up manually:

```bash
# Clone SwiftTerm at exact version
cd Vendor
git clone --depth 1 --branch v1.10.1 https://github.com/migueldeicaza/SwiftTerm.git

# Edit Vendor/SwiftTerm/Package.swift
# Remove trailing commas from these lines (the comma at the end):
#   exclude: platformExcludes + ["Mac/README.md"],
# Should become:
#   exclude: platformExcludes + ["Mac/README.md"]
```

### Updating SwiftTerm

To update to a newer SwiftTerm version:

1. Remove existing: `rm -rf Vendor/SwiftTerm`
2. Edit `scripts/setup-vendor.sh` to change `SWIFTTERM_VERSION`
3. Run `./scripts/setup-vendor.sh`
4. Check if the patch still applies correctly
5. Build and test

## Project Structure

```
GalaxyPOC/
├── scripts/
│   └── setup-vendor.sh      # Vendor dependency setup
├── Vendor/                   # Vendored dependencies (gitignored)
│   └── SwiftTerm/           # SwiftTerm v1.10.1 (patched)
├── GalaxyPOC/               # Swift source files
├── project.yml              # XcodeGen project spec
├── SETUP.md                 # This file
└── GalaxyPOC.xcodeproj/     # Generated (don't edit directly)
```

## Troubleshooting

### "Invalid manifest" error during build

The SwiftTerm patch wasn't applied correctly. Re-run:
```bash
rm -rf Vendor/SwiftTerm
./scripts/setup-vendor.sh
```

### "No such module 'SwiftTerm'"

The Xcode project needs regeneration:
```bash
xcodegen generate
```

### Build succeeds but app crashes

Check Console.app for crash logs. Common issues:
- Claude binary not found (check `~/.local/bin/claude` exists)
- Missing entitlements for terminal access
