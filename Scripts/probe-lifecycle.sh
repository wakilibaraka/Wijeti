#!/bin/bash
# Launch / relaunch / update lifecycle probe.
#
# Uses a /tmp widget folder on purpose: /tmp is a symlink to /private/tmp, which is exactly
# the case that used to make one widget appear twice (the server's first scan used the path
# from -d, its watcher reported the resolved path). Every step below must show one id per file.
set -u
cd ~/Wijeti
PORT=41601
ROOT=$(mktemp -d /tmp/wijeti-life.XXXXXX)
WID="$ROOT/widgets"; SET="$ROOT/settings"; LOG="$ROOT/app.log"
mkdir -p "$WID" "$SET"
cp -R Resources/presets/DigitalClock.widget "$WID/"
APP=./build/Wijeti.app/Contents/MacOS/WijetiApp

state() { curl -s "http://127.0.0.1:$PORT/state/"; }
ids()   { state | python3 -c "import json,sys;d=json.load(sys.stdin);print(sorted(d['widgets']))"; }
hid()   { state | python3 -c "import json,sys;d=json.load(sys.stdin);print(sorted(k for k,v in d['settings'].items() if v.get('hidden')))"; }
count() { ids | python3 -c "import sys,ast;print(len(ast.literal_eval(sys.stdin.read())))"; }

start() { "$APP" --widgets "$WID" --settings "$SET" --port $PORT >> "$LOG" 2>&1 & echo $!; }
stop()  { kill "$1" 2>/dev/null; sleep 2; pkill -f "wijeti-life" 2>/dev/null; sleep 1; }

echo "ROOT=$ROOT   (resolves to $(cd "$ROOT" && pwd -P))"
echo "widget dir: $WID"

P=$(start); sleep 9
echo "1. first launch        -> $(ids)"

touch "$WID/DigitalClock.widget/index.jsx"; sleep 5
echo "2. after file edit     -> $(ids)   [1 entry expected: this is the duplicate bug]"

stop "$P"; P=$(start); sleep 9
echo "3. after relaunch      -> $(ids)   [same single id expected]"

cp -R Resources/presets/WeatherNow.widget "$WID/"; sleep 5
echo "4. add while running   -> $(ids)"

rm -rf "$WID/DigitalClock.widget"; sleep 5
echo "5. remove while running-> $(ids)"

stop "$P"

# Persistence: the server owns WidgetSettings.json, so seed it the way the app would leave it.
# Read the surviving id from a launch, stop, then relaunch with it marked hidden.
P=$(start); sleep 9
SURVIVOR=$(ids | python3 -c "import sys,ast;print(ast.literal_eval(sys.stdin.read())[0])")
stop "$P"
python3 - "$SET" "$SURVIVOR" <<'PY'
import json, sys, os
settings_dir, wid = sys.argv[1], sys.argv[2]
path = os.path.join(settings_dir, "WidgetSettings.json")
json.dump({wid: {"showOnAllScreens": True, "showOnMainScreen": False,
                 "showOnSelectedScreens": False, "hidden": True, "screens": []}},
          open(path, "w"))
print("seeded hidden=true for", wid)
PY
P=$(start); sleep 9
echo "6. hidden survives     -> hidden=$(hid)  ids=$(ids)"
stop "$P"

echo "--- app log highlights ---"
grep -E "widget library|first launch|Reloaded|restarting widget server|Wijeti starting" "$LOG" | head -8
echo "--- leftovers ---"
pgrep -fl "wijeti-life" || echo "no orphaned processes"
rm -rf "$ROOT"
echo "(cleaned $ROOT)"
