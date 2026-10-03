#!/bin/bash
# Debug build of "WinBar Dev" (local.winbar.dev), sign with the local identity, quit any running
# WinBar (production too), install to ~/Applications and launch. Production comes from the DMG/updater.
# Extra arguments are passed to WinBar, e.g. ./scripts/build-app.sh --log-events
# BUNDLE_ONLY=1 builds the production release bundle and stops after signing (used by the release workflow).
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="WinBar Local Signing"
if [[ ${BUNDLE_ONLY:-} == 1 ]]; then
    CONFIG=release NAME=WinBar EXE=WinBar
else
    CONFIG=debug NAME="WinBar Dev" EXE=WinBarDev
fi
APP=".build/$NAME.app"
DEST="$HOME/Applications/$NAME.app"

ids=$(security find-identity -v -p codesigning)
if [[ $ids != *"\"$IDENTITY\""* ]]; then
    echo "error: code-signing identity \"$IDENTITY\" not found." >&2
    echo "Run ./scripts/make-cert.sh in Terminal.app first." >&2
    exit 1
fi

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/WinBar" "$APP/Contents/MacOS/$EXE"
cp Info.plist "$APP/Contents/Info.plist"
if [[ $CONFIG == debug ]]; then
    pb() { /usr/libexec/PlistBuddy -c "$1" "$APP/Contents/Info.plist"; }
    pb "Set :CFBundleIdentifier local.winbar.dev"
    pb "Set :CFBundleName $NAME"
    pb "Set :CFBundleExecutable $EXE"
fi
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -d Resources/Fonts ]]; then
    cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
fi

codesign --force --sign "$IDENTITY" "$APP"
[[ ${BUNDLE_ONLY:-} == 1 ]] && exit 0   # CI: leave the signed .build/WinBar.app, don't install

# Quit production and dev (two bars can't coexist) and wait (up to 5 s) so `open` starts a fresh process.
pkill -x WinBar || true
pkill -x WinBarDev || true
for _ in {1..50}; do pgrep -x 'WinBar|WinBarDev' >/dev/null || break; sleep 0.1; done

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
mv "$APP" "$DEST"   # installs and removes the build copy: only one bundle with this ID

if [[ $# -gt 0 ]]; then
    open "$DEST" --args "$@"
else
    open "$DEST"
fi
echo "Back to production: pkill -x WinBarDev; open /Applications/WinBar.app"
