#!/bin/bash
# Writes updates/appcast-<arch>.xml for the DMG in dist/<arch>/ and signs it with the EdDSA key
# stored in the login Keychain (created once with Sparkle's generate_keys).
#
# Sparkle reads the feed named by SUFeedURL in the app. Each architecture has its own feed so an
# Intel Mac is never offered an Apple Silicon build.
#
# The feed is generated in a clean directory that holds only the new DMG, and the resulting item is
# then merged into the existing feed. Running generate_appcast over a directory with older DMGs
# would rewrite their download URLs to the current release tag (a 404 for an older release) and
# would build a delta against a DMG that is published under another tag.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-$(uname -m)}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
REPO="${REPO:-wakilibaraka/Wijeti}"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
DIR="$ROOT/dist/$ARCH"
FEED="$ROOT/updates/appcast-$ARCH.xml"
DMG="Wijeti-$VERSION-$ARCH.dmg"

[ -f "$DIR/$DMG" ] || { echo "missing $DIR/$DMG — run Scripts/make-dmg.sh first" >&2; exit 1; }
[ -x "$TOOLS/generate_appcast" ] || { echo "run 'swift package resolve' first" >&2; exit 1; }

# Release notes shown in the update dialog: Sparkle picks up a file named like the archive.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$DIR/$DMG" "$STAGE/"
if [ -f "$ROOT/RELEASE_NOTES.md" ]; then
  cp "$ROOT/RELEASE_NOTES.md" "$STAGE/Wijeti-$VERSION-$ARCH.md"
fi

echo "==> generating the $ARCH feed entry for $DMG"
"$TOOLS/generate_appcast" "$STAGE" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --embed-release-notes \
  -o "$STAGE/appcast-new.xml" >/dev/null

mkdir -p "$ROOT/updates"

# Merge the new item into the feed, newest first, keeping the older items exactly as they are.
python3 - "$FEED" "$STAGE/appcast-new.xml" <<'PY'
import pathlib
import re
import sys

feed_path, new_path = sys.argv[1], sys.argv[2]
item_re = re.compile(r"<item>.*?</item>", re.S)
version_re = re.compile(r"<sparkle:version>([^<]*)</sparkle:version>")
deltas_re = re.compile(r"[ \t]*<sparkle:deltas>.*?</sparkle:deltas>\n?", re.S)


def version_of(item):
    found = version_re.search(item)
    return int(found.group(1)) if found else 0


new_text = pathlib.Path(new_path).read_text()
new_items = item_re.findall(new_text)
if not new_items:
    sys.exit("make-appcast: the generated feed has no <item>")
new_item = deltas_re.sub("", new_items[0])

if pathlib.Path(feed_path).exists():
    old_text = pathlib.Path(feed_path).read_text()
    old_items = item_re.findall(old_text)
    head = old_text[: old_text.index("<item>")].rstrip() if old_items else old_text.rstrip()
    tail = old_text[old_text.rindex("</item>") + len("</item>") :] if old_items else ""
    tail = tail.strip("\n")
else:
    old_items = []
    head = new_text[: new_text.index("<item>")].rstrip()
    tail = "    </channel>\n</rss>"

items = [i for i in old_items if version_of(i) != version_of(new_item)]
items.append(new_item)
items.sort(key=version_of, reverse=True)

body = "".join(f"    {item}\n" for item in items)
out = head + "\n" + body + "\n" + tail + "\n"
pathlib.Path(feed_path).write_text(out)
print(f"make-appcast: wrote {feed_path} ({len(items)} item(s))")
PY

echo "==> wrote $FEED"
