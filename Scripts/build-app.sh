#!/bin/bash
# Builds Wijeti.app: Swift binary + the Node widget server + bundled presets + scripting
# definition, ad-hoc signed with the entitlement the bundled Node runtime needs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
# ARCH selects the target CPU: arm64 (Apple Silicon) or x86_64 (Intel). One build per
# architecture keeps each download small: only the matching Node runtime is bundled.
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "ARCH must be arm64 or x86_64 (got '$ARCH')" >&2; exit 1 ;;
esac
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT/BUILD_NUMBER")"
APP="${APP:-$ROOT/build/$ARCH/Wijeti.app}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/wakilibaraka/Wijeti/main}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "==> swift build -c $CONFIG --arch $ARCH"
swift build -c "$CONFIG" --arch "$ARCH" --package-path "$ROOT"
BIN_PATH="$(swift build -c "$CONFIG" --arch "$ARCH" --package-path "$ROOT" --show-bin-path)"

echo "==> assembling $APP (v$VERSION build $BUILD_NUMBER, $ARCH)"
case "$APP" in
  *.app) ;;
  *) echo "refusing to remove '$APP': APP must end in .app" >&2; exit 1 ;;
esac
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN_PATH/WijetiApp" "$APP/Contents/MacOS/WijetiApp"

# Sparkle (automatic updates) is embedded; the executable finds it through @rpath. The linker
# also records the absolute build-machine path as an rpath, which must not ship.
SPARKLE_FRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
while IFS= read -r RPATH; do
  case "$RPATH" in
    /usr/lib/swift|@*) ;;
    *) install_name_tool -delete_rpath "$RPATH" "$APP/Contents/MacOS/WijetiApp" ;;
  esac
done < <(otool -l "$APP/Contents/MacOS/WijetiApp" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}')
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/WijetiApp"

# The widget server: localnode, server.js, the bundled node binaries and public/.
cp -R "$ROOT/server/release" "$APP/Contents/Resources/release"

# Only the matching Node runtime ships; the other architecture's binary is ~75 MB of dead weight.
case "$ARCH" in
  arm64)  rm -f "$APP/Contents/Resources/release/node-x64" ;;
  x86_64) rm -f "$APP/Contents/Resources/release/node-arm64" ;;
esac

# Launcher for the one bundled runtime. The stock launcher picks node-arm64 whenever the process is
# translated by Rosetta, which is wrong for a build that only contains node-x64.
case "$ARCH" in arm64) NODE_BIN=node-arm64 ;; x86_64) NODE_BIN=node-x64 ;; esac
cat > "$APP/Contents/Resources/release/localnode" <<LAUNCHER
#!/bin/zsh
exec "\$(dirname "\$0")/$NODE_BIN" "\$@"
LAUNCHER
chmod +x "$APP/Contents/Resources/release/localnode"

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
cp "$ROOT/LICENSE" "$ROOT/NOTICE.md" "$APP/Contents/Resources/"
# Compile the asset catalog so the bundle gets a real AppIcon.icns (a raw .xcassets is ignored).
xcrun actool "$ROOT/Resources/Assets.xcassets" \
  --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 \
  --app-icon AppIcon \
  --output-partial-info-plist /dev/null >/dev/null
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
# Each architecture follows its own appcast, so an Intel Mac is never offered an arm64 build.
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $REPO_RAW/updates/appcast-$ARCH.xml" "$PLIST"

# Signing identity: "-" is ad-hoc; pass SIGN_IDENTITY="Developer ID Application: …" to release.
IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/Resources/Wijeti.entitlements"
echo "==> signing (identity: $IDENTITY)"
# Nested code is signed one piece at a time, innermost first: --deep skips or mis-signs the
# .node addons and the large Node binaries. Without disable-library-validation the bundled
# node aborts on dlopen of fsevents.node (Team-ID mismatch).
# Sparkle's helpers are signed inside-out, without the app's entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for PIECE in "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/XPCServices/Downloader.xpc" \
             "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  [ -e "$PIECE" ] && codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$PIECE"
done
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

echo "==> built $APP (Wijeti v$VERSION, $ARCH)"
