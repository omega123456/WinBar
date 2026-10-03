#!/bin/bash
# Release build, sign with the local identity, install to ~/Applications and launch.
# Extra arguments are passed to WinBar, e.g. ./scripts/build-app.sh --log-events
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="WinBar Local Signing"
APP=.build/WinBar.app
DEST="$HOME/Applications/WinBar.app"

ids=$(security find-identity -v -p codesigning)
if [[ $ids != *"\"$IDENTITY\""* ]]; then
    echo "error: code-signing identity \"$IDENTITY\" not found." >&2
    echo "Run ./scripts/make-cert.sh in Terminal.app first." >&2
    exit 1
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/WinBar "$APP/Contents/MacOS/WinBar"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -d Resources/Fonts ]]; then
    cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
fi

codesign --force --sign "$IDENTITY" "$APP"

# Quit the running copy and wait (up to 5 s) so `open` starts a fresh process.
pkill -x WinBar || true
for _ in {1..50}; do pgrep -x WinBar >/dev/null || break; sleep 0.1; done

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
mv "$APP" "$DEST"   # installs and removes .build/WinBar.app: only one bundle with this ID

if [[ $# -gt 0 ]]; then
    open "$DEST" --args "$@"
else
    open "$DEST"
fi
