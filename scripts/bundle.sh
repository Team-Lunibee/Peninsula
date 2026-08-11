#!/bin/bash
# Builds Dynamic.app from the SwiftPM executable.
#
# SwiftPM produces a bare Mach-O; a menu-bar agent needs a real bundle for
# LSUIElement, its Info.plist, and the entitlements the media bridge relies on.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Dynamic.app"
ADAPTER="$ROOT/.build/mediaremote-adapter"

if [ ! -d "$ADAPTER/MediaRemoteAdapter.framework" ]; then
    echo "==> Building MediaRemoteAdapter.framework"
    "$ROOT/scripts/build-mediaremote-adapter.sh"
fi

echo "==> swift build -c $CONFIG"
cd "$ROOT"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/Dynamic"

if [ ! -f "$BINARY" ]; then
    echo "error: built binary not found at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BINARY" "$APP/Contents/MacOS/Dynamic"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The adapter is loaded by perl at runtime via an absolute path, so it ships in
# Resources rather than Frameworks — nothing in this app links against it.
cp -R "$ADAPTER/MediaRemoteAdapter.framework" "$APP/Contents/Resources/"
cp "$ADAPTER/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp "$ADAPTER/LICENSE-mediaremote-adapter" "$APP/Contents/Resources/"

# Sign inner code before the bundle that contains it.
# Ad-hoc signing changes the code signature on every build, and macOS keys
# privacy grants (Downloads, Desktop, Accessibility) to that signature — so a
# rebuild silently revokes them and folder watching goes quiet. Set
# SIGN_IDENTITY to a real certificate to keep permissions across builds:
#   SIGN_IDENTITY="Apple Development: you@example.com" ./scripts/bundle.sh
# Prefer a real certificate automatically. Ad-hoc signatures change on every
# build, and macOS keys privacy grants (Accessibility, Downloads, Desktop) to
# the signature — so an ad-hoc rebuild silently revokes everything the user
# granted, while the stale entry stays in System Settings looking enabled.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(.*\)"/\1/p' | head -1)"
fi
IDENTITY="${SIGN_IDENTITY:--}"

if [ "$IDENTITY" = "-" ]; then
    echo "    warning: ad-hoc signing — privacy permissions reset on every build"
else
    echo "    signing as $IDENTITY"
fi

codesign --force --sign "$IDENTITY" --timestamp=none \
    "$APP/Contents/Resources/MediaRemoteAdapter.framework" >/dev/null

codesign --force --sign "$IDENTITY" --timestamp=none \
    --options runtime \
    --entitlements "$ROOT/Resources/Dynamic.entitlements" \
    "$APP" >/dev/null

echo "==> Verifying"
codesign --verify --deep --strict "$APP" && echo "    signature ok"

echo "==> $APP"
