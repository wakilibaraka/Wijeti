#!/bin/bash
# Assembles server/release: the portable Node widget engine that Wijeti.app embeds.
#
# `server/release` is gitignored because it carries ~170 MB of Node binaries. This script
# reproduces it. Once per machine; afterwards `Scripts/build-app.sh` just copies the result.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/server"
RELEASE="$SERVER/release"

if [ -x "$RELEASE/node-arm64" ] && [ -x "$RELEASE/node-x64" ] && [ -f "$RELEASE/server.js" ]; then
  echo "==> server/release already present, nothing to do"
  exit 0
fi

NODE_VERSION="${NODE_VERSION:-v20.18.1}"

echo "==> npm ci (widget engine dependencies)"
(cd "$SERVER" && npm ci --no-audit --no-fund)

mkdir -p "$RELEASE"

echo "==> building server.js"
(cd "$SERVER" && npm run build)

cp -R "$SERVER/public" "$RELEASE/public"
cp -R "$SERVER/node_modules" "$RELEASE/node_modules"
cp -L "$SERVER/package.json" "$RELEASE/package.json.tmp" && mv -f "$RELEASE/package.json.tmp" "$RELEASE/package.json"
if [ -f "$SERVER/server.js" ]; then
  cp "$SERVER/server.js" "$RELEASE/server.js"
fi

# Upstream ships `release/` prebuilt with the node binaries already in it; if this checkout
# still has them, keep them, otherwise download the matching official build.
for BIN in node-arm64 node-x64; do
  if [ -x "$RELEASE/$BIN" ]; then
    continue
  fi
  echo "==> downloading node $NODE_VERSION ($BIN)"
  URL="https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-darwin-${BIN#node-}.tar.gz"
  TMP="$(mktemp -d)"
  curl -fsSL "$URL" -o "$TMP/node.tar.gz"
  # Verify against the SHASUMS256.txt published next to the download before unpacking.
  EXPECTED="$(curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" \
    | awk -v f="node-$NODE_VERSION-darwin-${BIN#node-}.tar.gz" '$2 == f { print $1 }')"
  ACTUAL="$(shasum -a 256 "$TMP/node.tar.gz" | awk '{ print $1 }')"
  if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "checksum mismatch for $BIN download" >&2
    exit 1
  fi
  tar -xz -C "$TMP" -f "$TMP/node.tar.gz"
  cp "$TMP/node-$NODE_VERSION-darwin-${BIN#node-}/bin/node" "$RELEASE/$BIN"
  chmod +x "$RELEASE/$BIN"
  rm -rf "$TMP"
done

# `localnode` is the thin launcher the host spawns; it re-execs the right architecture's
# node with the bundled server.
cat > "$RELEASE/localnode" <<'LAUNCHER'
#!/bin/bash
# Picks the node binary matching this machine, then runs the widget server.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -m)" in
  arm64) NODE="$HERE/node-arm64" ;;
  *)     NODE="$HERE/node-x64" ;;
esac
exec "$NODE" "$@"
LAUNCHER
chmod +x "$RELEASE/localnode"

echo "==> runtime ready at $RELEASE"
