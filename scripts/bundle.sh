#!/bin/bash
# Builds Dynamic.app from the SwiftPM executable.
#
# SwiftPM produces a bare Mach-O; a menu-bar agent needs a real bundle for
# LSUIElement, its Info.plist, and the entitlements the media bridge relies on.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
NAME="Dynamic"
APP="$ROOT/build/$NAME.app"
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

# Install over the copy that is actually used.
#
# The login item registers a path, and macOS keys privacy grants to the bundle
# at that path, so /Applications/Dynamic.app has to be the build you just made
# — otherwise you spend an afternoon fixing something and keep running the
# version from this morning. Replacing in place keeps the path, and the
# signature is unchanged, so Accessibility and Focus survive.
#
# Set NO_INSTALL=1 to build without touching it.
INSTALLED="/Applications/$NAME.app"
if [ "${NO_INSTALL:-0}" = "1" ]; then
    echo "==> Skipping install (NO_INSTALL=1)"
elif [ ! -w /Applications ]; then
    echo "    warning: /Applications is not writable — not installing" >&2
else
    echo "==> Installing to $INSTALLED"
    WAS_RUNNING=0
    if pgrep -f "$INSTALLED/Contents/MacOS/$NAME" >/dev/null 2>&1; then
        WAS_RUNNING=1
        # Terminate rather than kill: the app catches SIGTERM to reap the
        # adapter's perl child, and SIGKILL would strand it.
        pkill -f "$INSTALLED/Contents/MacOS/$NAME" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -f "$INSTALLED/Contents/MacOS/$NAME" >/dev/null 2>&1 || break
            sleep 0.3
        done
    fi

    rm -rf "$INSTALLED"
    # ditto, not cp: it preserves the extended attributes the signature covers.
    ditto "$APP" "$INSTALLED"
    codesign --verify --deep --strict "$INSTALLED" && echo "    installed and verified"

    if [ "$WAS_RUNNING" = "1" ]; then
        open "$INSTALLED"
        echo "    relaunched"
    fi
fi

echo "==> $APP"
