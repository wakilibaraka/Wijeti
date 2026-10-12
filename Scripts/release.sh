#!/bin/bash
# Builds everything for one release: both architectures, DMGs, checksums and update feeds.
# Nothing is published; the last lines print the commands to do that by hand.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

cd "$ROOT"
swift package resolve
swift test

for ARCH in arm64 x86_64; do
  export ARCH
  "$ROOT/Scripts/build-app.sh"
  "$ROOT/Scripts/make-dmg.sh"
  "$ROOT/Scripts/make-appcast.sh"
done

cat <<DONE

Built v$VERSION:
$(ls -1 dist/*/*.dmg dist/*/*.sha256)

Publish (after reviewing the DMGs):
  git add updates VERSION BUILD_NUMBER && git commit -m "Release v$VERSION" && git push
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION --prerelease --title "Wijeti $VERSION" --notes-file RELEASE_NOTES.md dist/*/*.dmg dist/*/*.sha256
DONE
