#!/usr/bin/env bash
# Release Wijeti: builds, packages, signs, and refreshes the per-architecture
# Sparkle feeds. Run from the repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION)"
BUILD_NUMBER="$(cat BUILD_NUMBER)"
BUILD_NUMBER=$((BUILD_NUMBER + 1))
echo "$BUILD_NUMBER" > BUILD_NUMBER

./Scripts/tests.sh
./Scripts/build-runtime.sh

ASSETS=()
for ARCH in arm64 x86_64; do
  rm -rf "build/$ARCH" "dist/$ARCH" "build/dsym/$ARCH" "dist/dsym/$ARCH"
  ARCH="$ARCH" SIGN_IDENTITY="${SIGN_IDENTITY:-}" BUILD_NUMBER="$BUILD_NUMBER" \
    ./Scripts/build-app.sh
  ASSETS+=( "$(ls -A dist/$ARCH/Wijeti-*.dmg | head -n1)" )
  ./Scripts/sign-dsym.sh "$ARCH"
done

echo "=== creating DMG release notes ==="
cat > RELEASE_NOTES.md << EOF
Wijeti $VERSION Release Notes
=============================

Build number: $BUILD_NUMBER
Release date: $(date -u +"%Y-%m-%d")

## What's new
- Automatic updates via Sparkle (Settings → General → Updates).
- Widget Library, live preview, and bulk install.
- Per-app permissions (Automation, Calendars, Camera, Bluetooth, Full Disk, …).
- Menu bar health indicator, refresh/reload/reload, preferences, update check.

## Artifacts
EOF
for ASSET in "${ASSETS[@]}"; do
  SIZE=$(stat -f%z "$ASSET" 2>/dev/null || stat -c%s "$ASSET" 2>/dev/null || echo "?")
  SHA=$(shasum -a 256 "$ASSET" | cut -d' ' -f1)
  echo "- $ASSET ($(format_size "$SIZE"))" >> RELEASE_NOTES.md
  echo "$SHA  $ASSET" >> "dist/${ASSET##*/}.sha256"
done
echo "Generated RELEASE_NOTES.md and .sha256 for ${ASSETS[*]}"

./Scripts/tag-and-push.sh
