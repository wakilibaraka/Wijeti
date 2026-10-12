#!/bin/bash
# Packages build/<arch>/Wijeti.app into dist/<arch>/Wijeti-<version>-<arch>.dmg with a drag-to-
# Applications layout, a first-run help file and a SHA-256 checksum.
#
#   ARCH=arm64  Scripts/make-dmg.sh
#   ARCH=x86_64 Scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-$(uname -m)}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="${APP:-$ROOT/build/$ARCH/Wijeti.app}"
OUT_DIR="$ROOT/dist/$ARCH"
DMG="$OUT_DIR/Wijeti-$VERSION-$ARCH.dmg"

[ -d "$APP" ] || { echo "missing $APP — run ARCH=$ARCH Scripts/build-app.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> staging $ARCH $VERSION"
ditto "$APP" "$STAGE/Wijeti.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/Resources/Read Me First.txt" "$STAGE/Read Me First.txt"

mkdir -p "$OUT_DIR"
rm -f "$DMG"
echo "==> creating $DMG"
hdiutil create -volname "Wijeti $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null

( cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "==> $(du -h "$DMG" | cut -f1)  $DMG"
cat "$DMG.sha256"
