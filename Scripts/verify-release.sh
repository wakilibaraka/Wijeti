#!/usr/bin/env bash
# Verifies the release artifacts before they are published.
#
#   Scripts/verify-release.sh              # check the local artifacts against the feeds
#   Scripts/verify-release.sh --published  # also check them against the GitHub release
#
# For every DMG in dist/<arch>/ it checks that
#   - the Sparkle feed (updates/appcast-<arch>.xml) has an entry for that file and that its byte
#     length and EdDSA signature match the file, recomputed with the private key in the login
#     keychain. A feed that disagrees with the bytes it serves makes Sparkle reject the update,
#     so this is the check that catches a stale or mismatched build.
#   - the .sha256 file next to the DMG matches the DMG.
#   - the feed entry points at the release that holds that file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
CHECK_PUBLISHED=0
[ "${1:-}" = "--published" ] && CHECK_PUBLISHED=1

FAILED=0

fail() { echo "  FAIL: $*" >&2; FAILED=1; }
ok() { echo "  ok:   $*"; }

[ -x "$SPARKLE_BIN" ] || { echo "verify-release: $SPARKLE_BIN is missing — run 'swift package resolve'" >&2; exit 1; }

for ARCH_DIR in dist/*/; do
  ARCH="$(basename "$ARCH_DIR")"
  FEED="updates/appcast-$ARCH.xml"

  for DMG in "$ARCH_DIR"Wijeti-*.dmg; do
    [ -f "$DMG" ] || continue
    DMG_NAME="$(basename "$DMG")"
    DMG_DIR="$(dirname "$DMG")"

    echo "=== $ARCH: $DMG_NAME"

    # -- the checksum file
    if [ -f "$DMG.sha256" ]; then
      if ( cd "$DMG_DIR" && shasum -a 256 -c "$DMG_NAME.sha256" >/dev/null 2>&1 ); then
        ok "$DMG_NAME.sha256 matches the DMG"
      else
        fail "$DMG_NAME.sha256 does not match the DMG"
      fi
    else
      fail "$DMG_NAME.sha256 is missing"
    fi

    # -- the Sparkle feed entry
    if [ ! -f "$FEED" ]; then
      fail "$FEED is missing"
      continue
    fi
    ENCLOSURE="$(grep -o '<enclosure[^>]*>' "$FEED" | grep -F "$DMG_NAME" | head -n1 || true)"
    if [ -z "$ENCLOSURE" ]; then
      fail "$FEED has no entry for $DMG_NAME"
      continue
    fi
    FEED_LENGTH="$(printf '%s' "$ENCLOSURE" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
    FEED_SIGNATURE="$(printf '%s' "$ENCLOSURE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
    FEED_URL="$(printf '%s' "$ENCLOSURE" | sed -n 's/.*url="\([^"]*\)".*/\1/p')"

    SIGNED="$("$SPARKLE_BIN" "$DMG" </dev/null)"
    REAL_LENGTH="$(printf '%s' "$SIGNED" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
    REAL_SIGNATURE="$(printf '%s' "$SIGNED" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"

    if [ "$FEED_LENGTH" = "$REAL_LENGTH" ]; then
      ok "feed length $FEED_LENGTH matches the DMG"
    else
      fail "feed length $FEED_LENGTH does not match the DMG ($REAL_LENGTH)"
    fi
    if [ "$FEED_SIGNATURE" = "$REAL_SIGNATURE" ]; then
      ok "feed signature matches the DMG"
    else
      fail "feed signature does not match the DMG — Sparkle would reject the update"
    fi
    case "$FEED_URL" in
      *"/$DMG_NAME")
        ok "feed points at $DMG_NAME"
        case "$DMG_NAME" in
          "Wijeti-$VERSION-$ARCH.dmg")
            case "$FEED_URL" in
              *"/download/$TAG/"*) ok "the current build points at $TAG" ;;
              *) fail "the current build points at '$FEED_URL', expected the $TAG release" ;;
            esac
            ;;
        esac
        ;;
      *) fail "feed URL '$FEED_URL' does not point at $DMG_NAME" ;;
    esac

    # -- the published release
    if [ "$CHECK_PUBLISHED" -eq 1 ] && command -v gh >/dev/null 2>&1; then
      # Each item lives in the release its feed URL points at, not necessarily in the current one.
      PUBLISHED_TAG="$(printf '%s' "$FEED_URL" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')"
      if [ -z "$PUBLISHED_TAG" ]; then
        fail "could not read the release tag out of '$FEED_URL'"
      elif gh release download "$PUBLISHED_TAG" --pattern "$DMG_NAME" --dir "$DMG_DIR" --clobber >/dev/null 2>&1; then
        PUBLISHED_SHA="$(shasum -a 256 "$DMG_DIR/$DMG_NAME" | cut -d' ' -f1)"
        if [ "$PUBLISHED_SHA" = "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" ]; then
          ok "the published $DMG_NAME ($PUBLISHED_TAG) is byte-identical to the local one"
        else
          fail "the published $DMG_NAME ($PUBLISHED_TAG) differs from the local one"
        fi
      else
        fail "$DMG_NAME is not published in the $PUBLISHED_TAG release"
      fi
    fi
  done
done

if [ "$FAILED" -ne 0 ]; then
  echo "verify-release: FAILED" >&2
  exit 1
fi
echo "verify-release: all artifacts agree with the feeds"
