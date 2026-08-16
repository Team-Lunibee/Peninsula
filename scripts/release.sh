#!/bin/bash
# Builds, signs, notarises and staples Dynamic.app for direct distribution.
#
# Gatekeeper rejects anything that is merely signed. Without a notarisation
# ticket every download shows "확인되지 않은 개발자" and has to be opened from
# the context menu, which is where most people give up — so a release that
# skips this step is not really a release.
#
# Notarisation needs a **Developer ID Application** certificate. Apple
# Distribution is for the App Store and Apple Development is for your own Macs;
# neither can be notarised, and both fail with an unhelpful error late in the
# submission. Create one at developer.apple.com › Certificates › + ›
# Developer ID Application, then download and double-click it.
#
# One-time credential setup, storing an app-specific password in the keychain
# (make the password at appleid.apple.com › Sign-In and Security):
#
#   xcrun notarytool store-credentials Dynamic-notary \
#       --apple-id you@example.com \
#       --team-id J9GX644K88 \
#       --password xxxx-xxxx-xxxx-xxxx
#
# Then:
#
#   ./scripts/release.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="Dynamic"
APP="$ROOT/build/$NAME.app"
DIST="$ROOT/build/dist"
PROFILE="${NOTARY_PROFILE:-Dynamic-notary}"

# ---------------------------------------------------------------- identity

# Match on the certificate's own name rather than taking the first identity in
# the list, which is what bundle.sh does and is wrong here: picking up an Apple
# Distribution certificate produces a bundle that builds, installs and runs
# fine, and is then rejected by notarisation minutes later.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi

if [ -z "$SIGN_IDENTITY" ]; then
    cat >&2 <<'EOF'
error: no "Developer ID Application" certificate in the keychain.

    Notarised distribution needs that specific certificate type. Check what
    you have with:

        security find-identity -v -p codesigning

    An "Apple Distribution" or "Apple Development" identity will not work —
    those are for the App Store and for local development.

    Create one at https://developer.apple.com/account/resources/certificates
    (Certificates › + › Developer ID Application), download it, and
    double-click to add it to the keychain.
EOF
    exit 1
fi

echo "==> Signing as $SIGN_IDENTITY"

# ------------------------------------------------------------------- build

# NO_INSTALL: a release build must not replace the copy in /Applications. It is
# signed with a different certificate than the dev build, so macOS treats it as
# a different app and drops every privacy grant the user has given.
#
# DYNAMIC_RELEASE: leaves the Motion Lab and the frame dumper out of the binary.
echo "==> Building"
NO_INSTALL=1 DYNAMIC_RELEASE=1 SIGN_IDENTITY="$SIGN_IDENTITY" \
    "$ROOT/scripts/bundle.sh" release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP/Contents/Info.plist")"
echo "    $NAME $VERSION ($BUILD)"

# ------------------------------------------------------- preflight the sig

# Check locally what the notary service would otherwise take several minutes to
# tell you: every Mach-O needs the hardened runtime and a secure timestamp.
echo "==> Checking the signature before submitting"

FLAGS="$(codesign -d --verbose=2 "$APP" 2>&1 | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p')"
case "$FLAGS" in
    *runtime*) echo "    hardened runtime ok" ;;
    *) echo "error: the app is not signed with the hardened runtime ($FLAGS)" >&2; exit 1 ;;
esac

if codesign -dvv "$APP" 2>&1 | grep -q "Timestamp="; then
    echo "    secure timestamp ok"
else
    echo "error: the signature has no secure timestamp — notarisation will reject it" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

# --------------------------------------------------------------- notarise

rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="$DIST/$NAME-$VERSION.zip"

# ditto -c -k --keepParent, not zip: the signature covers extended attributes
# and symlinks that a plain zip flattens, which invalidates it in transit.
echo "==> Packing $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF
error: no stored notarisation credentials under the profile "$PROFILE".

    Store them once with:

        xcrun notarytool store-credentials $PROFILE \\
            --apple-id you@example.com \\
            --team-id \$(security find-identity -v -p codesigning \\
                | sed -n 's/.*(\\([A-Z0-9]*\\))".*/\\1/p' | head -1) \\
            --password xxxx-xxxx-xxxx-xxxx

    The password is an app-specific password from appleid.apple.com, not your
    Apple ID password.
EOF
    exit 1
fi

echo "==> Submitting to Apple (this takes a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | sed 's/^/    /'

# ----------------------------------------------------------------- staple

# Staple the ticket into the bundle so a first launch works offline. Without
# it Gatekeeper has to reach Apple to check, and a machine with no network
# shows the same warning as an unsigned app.
echo "==> Stapling"
xcrun stapler staple "$APP" 2>&1 | sed 's/^/    /'

echo "==> Verifying as Gatekeeper sees it"
spctl -a -vvv -t install "$APP" 2>&1 | sed 's/^/    /'
xcrun stapler validate "$APP" 2>&1 | sed 's/^/    /'

# Re-pack: the archive above was made before the ticket existed, so shipping it
# would hand everyone an unstapled app that passed every check on this machine.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "==> $ZIP"
echo "    $(du -h "$ZIP" | cut -f1) · $NAME $VERSION ($BUILD)"
