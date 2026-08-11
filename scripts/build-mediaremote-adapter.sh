#!/bin/bash
# Builds MediaRemoteAdapter.framework from the vendored mediaremote-adapter
# sources without requiring cmake. Mirrors the flags in the upstream
# CMakeLists.txt: ARC on, default symbol visibility (the Perl loader resolves
# adapter_* symbols by name via DynaLoader), universal arm64 + x86_64.
#
# Upstream: https://github.com/ungive/mediaremote-adapter (BSD-3-Clause)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/references/mediaremote-adapter"
OUT="$ROOT/.build/mediaremote-adapter"
FW="$OUT/MediaRemoteAdapter.framework"
NAME="MediaRemoteAdapter"
VERSION_SHORT="0.1"
VERSION_FULL="0.1.0"

# Vendored rather than committed: it is a third-party BSD-3 project and the
# repository should carry our code, not a copy of theirs.
if [ ! -d "$SRC" ]; then
    echo "==> Fetching mediaremote-adapter (BSD-3-Clause)"
    mkdir -p "$ROOT/references"
    git clone --depth 1 https://github.com/ungive/mediaremote-adapter.git "$SRC" || {
        echo "error: could not fetch mediaremote-adapter" >&2
        exit 1
    }
fi

rm -rf "$FW"
mkdir -p "$FW/Versions/A/Resources" "$FW/Versions/A/Headers"

SOURCES=(
    src/adapter/env.m
    src/adapter/get.m
    src/adapter/globals.m
    src/adapter/keys.m
    src/adapter/now_playing.m
    src/adapter/repeat.m
    src/adapter/seek.m
    src/adapter/send.m
    src/adapter/shuffle.m
    src/adapter/speed.m
    src/adapter/stream.m
    src/adapter/test.m
    src/private/MediaRemote.m
    src/utility/Debounce.m
    src/utility/helpers.m
)

ABS_SOURCES=()
for s in "${SOURCES[@]}"; do ABS_SOURCES+=("$SRC/$s"); done

echo "==> Compiling $NAME (arm64 + x86_64)"
clang \
    -arch arm64 -arch x86_64 \
    -dynamiclib \
    -fobjc-arc \
    -fvisibility=default \
    -O2 \
    -mmacosx-version-min=13.0 \
    -I"$SRC/include" \
    -I"$SRC/src" \
    -framework Foundation \
    -framework AppKit \
    -framework UniformTypeIdentifiers \
    -install_name "@rpath/$NAME.framework/Versions/A/$NAME" \
    -compatibility_version 1.0.0 \
    -current_version "$VERSION_FULL" \
    -o "$FW/Versions/A/$NAME" \
    "${ABS_SOURCES[@]}"

cp "$SRC/include/MediaRemoteAdapter.h" "$FW/Versions/A/Headers/"
cp "$SRC/bin/mediaremote-adapter.pl" "$OUT/"
cp "$SRC/LICENSE" "$OUT/LICENSE-mediaremote-adapter"

cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>com.vandenbe.$NAME</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION_SHORT</string>
	<key>CFBundleVersion</key>
	<string>$VERSION_FULL</string>
</dict>
</plist>
PLIST

# Framework bundles need the classic versioned symlink layout or codesign and
# dyld both complain when the framework is embedded in an .app.
ln -sfn A "$FW/Versions/Current"
ln -sfn "Versions/Current/$NAME" "$FW/$NAME"
ln -sfn Versions/Current/Resources "$FW/Resources"
ln -sfn Versions/Current/Headers "$FW/Headers"

codesign --force --sign - --timestamp=none "$FW" >/dev/null 2>&1

echo "==> Built $FW"
lipo -archs "$FW/Versions/A/$NAME"

# Smoke test: the adapter must be loadable and entitled through system perl.
echo "==> Testing adapter entitlement"
if /usr/bin/perl "$OUT/mediaremote-adapter.pl" "$FW" get >/dev/null 2>&1; then
    echo "    ok — adapter responds"
else
    echo "    warning: 'get' returned non-zero (this is expected when nothing has ever played)" >&2
fi
