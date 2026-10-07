#!/bin/bash
# Builds Wijeti.app: Swift binary + the Node widget server + bundled presets + scripting
# definition, ad-hoc signed with the entitlement the bundled Node runtime needs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="${APP:-$ROOT/build/Wijeti.app}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN_PATH="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/WijetiApp" "$APP/Contents/MacOS/WijetiApp"

# The widget server: localnode, server.js, the bundled node binaries and public/.
cp -R "$ROOT/server/release" "$APP/Contents/Resources/release"

# `server/release/package.json` is a symlink to `server/package.json` in the repo, which
# would dangle inside the bundle (and makes codesign reject it). Dereference it.
RELEASE="$APP/Contents/Resources/release"
if [ -L "$RELEASE/package.json" ]; then
  cp -L "$ROOT/server/package.json" "$RELEASE/package.json.real"
  mv -f "$RELEASE/package.json.real" "$RELEASE/package.json"
fi

# The widget library: bundled presets plus the Catalog.json the picker reads.
cp -R "$ROOT/Resources/presets" "$APP/Contents/Resources/presets"

cp "$ROOT/Resources/Wijeti.sdef" "$APP/Contents/Resources/Wijeti.sdef"
cp -R "$ROOT/Resources/Assets.xcassets" "$APP/Contents/Resources/Assets.xcassets"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> signing (ad-hoc)"
# Without com.apple.security.cs.disable-library-validation the bundled node aborts on
# dlopen of fsevents.node (Team-ID mismatch), which costs three ports' worth of confusion.
codesign --force --deep --sign - \
  --entitlements "$ROOT/Resources/Wijeti.entitlements" \
  "$APP"
codesign --verify --deep --strict "$APP"

echo "==> built $APP (Wijeti v0.1.0)"
