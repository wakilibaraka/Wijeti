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
case "$APP" in
  *.app) ;;
  *) echo "refusing to remove '$APP': APP must end in .app" >&2; exit 1 ;;
esac
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

# Symlinks inside node_modules (the .bin shims, workspace links) either dangle once copied or
# point outside the bundle, and codesign rejects both. Drop the shims and flatten the rest.
find "$RELEASE" -type d -name .bin -prune -exec rm -rf {} +
while IFS= read -r LINK; do
  TARGET="$(cd "$(dirname "$LINK")" && readlink "$LINK")"
  RESOLVED="$(cd "$(dirname "$LINK")" && python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TARGET")"
  case "$RESOLVED" in
    "$RELEASE"/*) ;;                       # stays inside the bundle: keep as-is
    *)
      rm "$LINK"
      if [ -e "$ROOT/server/release/${LINK#$RELEASE/}" ]; then
        cp -RL "$ROOT/server/release/${LINK#$RELEASE/}" "$LINK"
      fi
      ;;
  esac
done < <(find "$RELEASE" -type l)
if find "$RELEASE" -type l ! -exec test -e {} \; -print | grep -q .; then
  echo "dangling symlinks remain in the bundle:" >&2
  find "$RELEASE" -type l ! -exec test -e {} \; -print >&2
  exit 1
fi

# The widget library: bundled presets plus the Catalog.json the picker reads.
cp -R "$ROOT/Resources/presets" "$APP/Contents/Resources/presets"

cp "$ROOT/Resources/Wijeti.sdef" "$APP/Contents/Resources/Wijeti.sdef"
# Compile the asset catalog so the bundle gets a real AppIcon.icns (a raw .xcassets is ignored).
xcrun actool "$ROOT/Resources/Assets.xcassets" \
  --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 \
  --app-icon AppIcon \
  --output-partial-info-plist /dev/null >/dev/null
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Signing identity: "-" is ad-hoc; pass SIGN_IDENTITY="Developer ID Application: …" to release.
IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/Resources/Wijeti.entitlements"
echo "==> signing (identity: $IDENTITY)"
# Nested code is signed one piece at a time, innermost first: --deep skips or mis-signs the
# .node addons and the large Node binaries. Without disable-library-validation the bundled
# node aborts on dlopen of fsevents.node (Team-ID mismatch).
while IFS= read -r NESTED; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$NESTED"
done < <(find "$APP/Contents/Resources/release" -type f \( -name '*.node' -o -name '*.dylib' \))
for NODE in "$APP/Contents/Resources/release"/node-*; do
  [ -f "$NODE" ] || continue
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$NODE"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> built $APP (Wijeti v0.1.0)"
