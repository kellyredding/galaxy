# Galaxy.app Development

## Building

Always build via Makefile to avoid polluting Xcode's DerivedData:

```
cd ~/projects/kellyredding/galaxy/GalaxyApp && make build
```

Never run `xcodebuild` directly — the Makefile ensures
`-derivedDataPath build` is always set.

## Launch Services Hygiene

Multiple copies of Galaxy.app with the same bundle ID cause macOS
to route `galaxy://` URLs to the wrong instance. After building,
check for and clean up stale registrations:

```bash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

# Check all registered Galaxy.app paths
$LSREGISTER -dump | grep -B1 "galaxy" | grep -i "path.*Galaxy.app"

# The only valid path is:
# ~/projects/kellyredding/galaxy/GalaxyApp/build/Build/Products/Debug/Galaxy.app

# Unregister any other paths:
# $LSREGISTER -u /path/to/stale/Galaxy.app

# Common stale locations:
# ~/Library/Developer/Xcode/DerivedData/GalaxyApp-*/Build/Products/*/Galaxy.app
# ~/projects/kellyredding/galaxy-poc/GalaxyApp/build/Build/Products/*/Galaxy.app
# ~/projects/kellyredding/galaxy/GalaxyApp/build/Build/Products/Release/Galaxy.app.bak
```

If stale copies exist on disk, delete them after unregistering.

## Restarting Galaxy.app After a Build

After building, quit the running instance, clean up the socket,
and relaunch — don't ask the user to do this:

```bash
pkill -9 -f "Galaxy.app/Contents/MacOS/Galaxy" 2>/dev/null
sleep 2
rm -f ~/.claude/galaxy/galaxy.sock ~/.claude/galaxy/galaxy.sock.lock
open ~/projects/kellyredding/galaxy/GalaxyApp/build/Build/Products/Debug/Galaxy.app
```

Wait 2 seconds after `pkill -9` before relaunching — the lock file
needs time to release.

Verify exactly one instance is running:

```bash
pgrep -fl "Galaxy.app/Contents/MacOS/Galaxy"
```
