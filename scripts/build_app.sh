#!/usr/bin/env bash
# Assemble a lean .app bundle from the SwiftPM build product.
# Usage: scripts/build_app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="SoundCtl"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/build/$APP_NAME.app"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Prefer a stable self-signed identity ("SoundCtl Self-Signed", created by
# scripts/setup-signing.sh): its designated requirement is keyed on the cert
# hash, not the per-build cdhash, so TCC grants (Accessibility) and Launch-at-
# Login persist across rebuilds. Fall back to ad-hoc if the identity is absent.
SIGN_IDENTITY="SoundCtl Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "==> codesign ($SIGN_IDENTITY)"
    codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "==> codesign (ad-hoc — run scripts/setup-signing.sh for a persistent Accessibility grant)"
    codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "==> built $APP_DIR"
