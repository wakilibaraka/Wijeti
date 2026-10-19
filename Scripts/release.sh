#!/usr/bin/env bash
# Release Wijeti: builds both architectures, packages and signs the DMGs, refreshes the
# per-architecture Sparkle feeds, tags the commit and publishes the GitHub release.
#
#   Scripts/release.sh              # full release
#   Scripts/release.sh --dry-run    # print every step, change nothing
#
# Requirements:
#   - Xcode with the Swift toolchain, and `gh` authenticated with write access
#   - the Sparkle EdDSA private key in the login keychain (Scripts/make-appcast.sh signs with it)
#   - RELEASE_NOTES.md written for the version in VERSION (it becomes the release body)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "usage: Scripts/release.sh [--dry-run]" >&2; exit 2 ;;
esac

REPO="${REPO:-wakilibaraka/Wijeti}"
ARCHES=(arm64 x86_64)
VERSION="$(tr -d '[:space:]' < VERSION)"
NOTES="RELEASE_NOTES.md"
TAG="v$VERSION"

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    printf '==> %s\n' "$*"
    "$@"
  fi
}

fail() { echo "release: $*" >&2; exit 1; }

# A dry run only reports what would block a live release; a live run stops on it.
block() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] WARNING: %s\n' "$*"
  else
    fail "$*"
  fi
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== Wijeti $VERSION release (dry run) ==="
else
  echo "=== Wijeti $VERSION release (live) ==="
fi

# ---------------------------------------------------------------- preflight
for TOOL in swift codesign hdiutil git gh; do
  command -v "$TOOL" >/dev/null 2>&1 || fail "missing required tool: $TOOL"
done
[ -f "$NOTES" ] || fail "$NOTES is missing — write the release notes for $VERSION first"
[ "$(head -1 "$NOTES")" = "## Wijeti $VERSION" ] \
  || fail "$NOTES starts with '$(head -1 "$NOTES")' but this release is $VERSION"
if [ "$DRY_RUN" -eq 0 ]; then
  gh auth status >/dev/null 2>&1 || fail "gh is not authenticated (run 'gh auth login')"
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  block "tag $TAG already exists — bump VERSION in VERSION to cut a new release"
fi
git diff --quiet || block "the working tree is dirty — commit or stash your changes first"

# ------------------------------------------------------------ build number
CURRENT_BUILD="$(tr -d '[:space:]' < BUILD_NUMBER)"
BUILD_NUMBER=$((CURRENT_BUILD + 1))
echo "==> build number $CURRENT_BUILD -> $BUILD_NUMBER"
if [ "$DRY_RUN" -eq 0 ]; then
  echo "$BUILD_NUMBER" > BUILD_NUMBER
fi

# ------------------------------------------------------------- build + test
run swift test
run ./Scripts/build-runtime.sh

ASSETS=()
for ARCH in "${ARCHES[@]}"; do
  echo "--- $ARCH ---"
  ARCH="$ARCH" BUILD_NUMBER="$BUILD_NUMBER" run ./Scripts/build-app.sh
  ARCH="$ARCH" run ./Scripts/make-dmg.sh
  ARCH="$ARCH" run ./Scripts/make-appcast.sh
  DMG="dist/$ARCH/Wijeti-$VERSION-$ARCH.dmg"
  [ -f "$DMG" ] || fail "expected $DMG — the DMG step did not produce it"
  ASSETS+=("$DMG" "$DMG.sha256")
done

# ------------------------------------------------------- verify before publish
# The feeds are served to installed copies of the app, so a feed that does not match the
# bytes it points at silently breaks updates. Fail the release instead of publishing that.
run ./Scripts/verify-release.sh

# ------------------------------------------------- commit, tag and push feeds
if [ "$DRY_RUN" -eq 0 ]; then
  git add updates BUILD_NUMBER
  if ! git diff --cached --quiet; then
    git commit -m "Refresh Sparkle feeds and build number for $VERSION"
  fi
  git tag -a "$TAG" -m "Release $VERSION"
fi
run git push origin main
run git push origin "$TAG"

# --------------------------------------------------------- publish the release
if [ "$DRY_RUN" -eq 0 ]; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "==> release $TAG exists — refreshing its assets and notes"
    gh release upload "$TAG" "${ASSETS[@]}" --clobber
    gh release edit "$TAG" --title "Wijeti $VERSION" --notes-file "$NOTES" --prerelease
  else
    gh release create "$TAG" --title "Wijeti $VERSION" --notes-file "$NOTES" --prerelease "${ASSETS[@]}"
  fi
fi

echo
echo "=== released $VERSION ==="
echo "  tag:     $TAG"
echo "  assets:  ${ASSETS[*]}"
echo "  release: https://github.com/$REPO/releases/tag/$TAG"
