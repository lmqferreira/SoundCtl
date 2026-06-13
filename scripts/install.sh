#!/usr/bin/env bash
# Build a release SoundCtl.app and install it to /Applications.
#
# Installing to /Applications (with a stable code signature) is required for
# "Launch at Login" (SMAppService) to register reliably and for the volume-key
# Accessibility grant to stick across updates.
#
# Usage: scripts/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SoundCtl"
DEST="/Applications/$APP_NAME.app"

"$ROOT/scripts/build_app.sh" release

# Quit a running instance so the bundle can be replaced cleanly.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "==> quitting running $APP_NAME"
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    sleep 1
fi

echo "==> installing to $DEST"
rm -rf "$DEST"
cp -R "$ROOT/build/$APP_NAME.app" "$DEST"

echo "==> launching"
open "$DEST"

echo "==> installed $DEST"
echo "    Tip: grant Accessibility (right-click the icon ->"
echo "    \"Grant Accessibility Access for Volume Keys…\") to control monitor volume"
echo "    with the hardware volume keys."
