#!/bin/bash
# Writes updates/appcast-<arch>.xml for the DMG in dist/<arch>/ and signs it with the EdDSA key
# stored in the login Keychain (created once with Sparkle's generate_keys).
#
# Sparkle reads the feed named by SUFeedURL in the app. Each architecture has its own feed so an
# Intel Mac is never offered an Apple Silicon build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-$(uname -m)}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
REPO="${REPO:-wakilibaraka/Wijeti}"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
DIR="$ROOT/dist/$ARCH"

[ -f "$DIR/Wijeti-$VERSION-$ARCH.dmg" ] || { echo "missing DMG in $DIR — run Scripts/make-dmg.sh first" >&2; exit 1; }
[ -x "$TOOLS/generate_appcast" ] || { echo "run 'swift package resolve' first" >&2; exit 1; }

# Release notes shown in the update dialog: Sparkle picks up a file named like the archive.
if [ -f "$ROOT/RELEASE_NOTES.md" ]; then
  cp "$ROOT/RELEASE_NOTES.md" "$DIR/Wijeti-$VERSION-$ARCH.md"
fi

mkdir -p "$ROOT/updates"
"$TOOLS/generate_appcast" "$DIR" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --embed-release-notes \
  -o "$ROOT/updates/appcast-$ARCH.xml"
echo "==> wrote updates/appcast-$ARCH.xml"
