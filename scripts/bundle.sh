#!/bin/bash
# Builds Peninsula.app from the SwiftPM executable.
#
# SwiftPM produces a bare Mach-O; a menu-bar agent needs a real bundle for
# LSUIElement, its Info.plist, and the entitlements the media bridge relies on.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
NAME="Peninsula"
APP="$ROOT/build/$NAME.app"
ADAPTER="$ROOT/.build/mediaremote-adapter"

if [ ! -d "$ADAPTER/MediaRemoteAdapter.framework" ]; then
    echo "==> Building MediaRemoteAdapter.framework"
    "$ROOT/scripts/build-mediaremote-adapter.sh"
fi

# The Motion Lab and the frame dumper are compiled in unless this is a release.
# They exist for tuning the animation, and neither belongs in a build that goes
# to someone who just wants the app. scripts/release.sh sets PENINSULA_RELEASE=1;
# building here by hand keeps them.
#
# Each variant gets its own scratch path, and that is not tidiness. SwiftPM does
# not treat a change in -Xswiftc as a reason to recompile, so sharing one path
# means `swift build` reports "up to date" and hands back whichever variant was
# built last — silently shipping the Motion Lab inside a release, or dropping it
# from a dev build. Separate paths make the two impossible to confuse.
BUILD_FLAGS=()
SCRATCH="$ROOT/.build"
if [ "${PENINSULA_RELEASE:-0}" = "1" ]; then
    SCRATCH="$ROOT/.build-release"
    echo "==> Release build — dev tools excluded"
else
    BUILD_FLAGS=(-Xswiftc -DDEV_TOOLS)
fi

echo "==> swift build -c $CONFIG"
cd "$ROOT"
swift build -c "$CONFIG" --scratch-path "$SCRATCH" "${BUILD_FLAGS[@]}"
BINARY="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" "${BUILD_FLAGS[@]}" --show-bin-path)/Peninsula"

if [ ! -f "$BINARY" ]; then
    echo "error: built binary not found at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BINARY" "$APP/Contents/MacOS/Peninsula"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Localisations go straight into Contents/Resources, which is where Bundle.main
# looks. SwiftPM would otherwise put them in a Peninsula_Peninsula.bundle beside the
# binary — invisible to this hand-assembled app, and every string would silently
# fall back to its English key.
for LPROJ in "$ROOT"/Resources/*.lproj; do
    [ -d "$LPROJ" ] || continue
    cp -R "$LPROJ" "$APP/Contents/Resources/"
done

# The adapter is loaded by perl at runtime via an absolute path, so it ships in
# Resources rather than Frameworks — nothing in this app links against it.
cp -R "$ADAPTER/MediaRemoteAdapter.framework" "$APP/Contents/Resources/"
cp "$ADAPTER/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp "$ADAPTER/LICENSE-mediaremote-adapter" "$APP/Contents/Resources/"

# Sign inner code before the bundle that contains it.
#
# Prefer a real certificate automatically. Ad-hoc signatures change on every
# build, and macOS keys privacy grants (Accessibility, Downloads, Desktop) to
# the signature — so an ad-hoc rebuild silently revokes everything the user
# granted, while the stale entry stays in System Settings looking enabled.
# Pin one explicitly with:
#   SIGN_IDENTITY="Apple Development: you@example.com" ./scripts/bundle.sh
# Developer ID first, not simply the first identity in the list. macOS keys
# privacy grants to the signature, so a dev build signed with one certificate
# and a release signed with another are two different apps to it: testing here
# would grant permissions the shipped copy does not inherit. Preferring the
# release certificate everywhere means the app being tested is the app that
# ships. Anything else is a fallback for a machine without one.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi
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

# A secure timestamp, not --timestamp=none: notarisation rejects any signature
# without one, and it costs a single request to Apple's timestamp server. An
# ad-hoc signature cannot carry a timestamp at all, so it keeps the old flag —
# which also keeps the dev loop working with no network.
TIMESTAMP=(--timestamp)
[ "$IDENTITY" = "-" ] && TIMESTAMP=(--timestamp=none)

# The hardened runtime goes on the framework as well as the app. Notarisation
# checks every Mach-O in the bundle, not just the main executable, and rejects
# the submission if any of them lacks the runtime flag.
codesign --force --sign "$IDENTITY" "${TIMESTAMP[@]}" \
    --options runtime \
    "$APP/Contents/Resources/MediaRemoteAdapter.framework" >/dev/null

codesign --force --sign "$IDENTITY" "${TIMESTAMP[@]}" \
    --options runtime \
    --entitlements "$ROOT/Resources/Peninsula.entitlements" \
    "$APP" >/dev/null

echo "==> Verifying"
codesign --verify --deep --strict "$APP" && echo "    signature ok"

# Install over the copy that is actually used.
#
# The login item registers a path, and macOS keys privacy grants to the bundle
# at that path, so /Applications/Peninsula.app has to be the build you just made
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
