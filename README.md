# Wijeti

A native Swift desktop widget host for macOS, in the spirit of
[Übersicht](https://github.com/felixhageloh/uebersicht) — but rewritten from scratch in Swift,
built for Apple Silicon, and without asking you to open Finder.

```
┌──────────────────────────────────────────────┐
│  Wijeti.app            tray icon ▣           │
│    ├── Swift host      windows, menus, prefs │
│    └── bundled Node    widget engine (portable)│
└──────────────────────────────────────────────┘
```

## What it does

- **Widgets on the desktop.** Two borderless, click-through `WKWebView` windows per screen
  (desktop level and above other apps), driven by the widget server's own `/<screen>/<layer>`
  routing. Exactly how Übersicht works, so existing `.jsx` widgets render unchanged.
- **Onboarding without Finder.** The Widget Library (⌘L, or the tray) lists bundled widgets
  by category with search, installs them in one click, and lets you toggle each one on and
  off. Drag a widget folder onto the window, or use **Install Your Own…**, and it lands in
  the right place — you never need to know the path.
- **Permissions and data sources.** One pane lists the permissions widgets may need
  (Location, Full Disk Access, Automation, Notifications), shows the real status, and opens
  the exact System Settings pane. Weather uses Open-Meteo, which needs no API key.
- **AppleScript.** `refresh`, `reload`, `count widgets`, `every widget` with
  `id` / `hidden` / `showOnMainScreen` / `showOnAllScreens`.
- **Tray menu and a SwiftUI preferences window** for widgets, screens, permissions and
  data sources.

## Requirements

- macOS 15 or later, Apple Silicon (arm64)
- Xcode 16+ (`xcode-select --switch /Applications/Xcode.app`)
  — the `sdef`/`osacompile` tooling needs the full Xcode, not just the Command Line Tools.

## Build and run

```sh
git clone https://github.com/wakilibaraka/Wijeti.git
cd Wijeti

# 1. Assemble the widget runtime (downloads Node for your architecture once).
./Scripts/build-runtime.sh

# 2. Build, bundle and code-sign Wijeti.app
./Scripts/build-app.sh

# 3. Install
cp -R build/Wijeti.app /Applications/ && open -a /Applications/Wijeti.app
```

`build-app.sh` ad-hoc signs the bundle with
`com.apple.security.cs.disable-library-validation`. **That entitlement is mandatory**: without
it the bundled Node runtime aborts on `dlopen` of `fsevents.node` with a Team-ID mismatch.

## Layout

```
Sources/WijetiCore/     portable models + server supervision — no AppKit import
Sources/WijetiMacOS/    AppKit host: windows, tray, preferences, web views
Sources/WijetiApp/      @main executable, options parsing, snapshot proof
Tests/WijetiCoreTests/  unit tests (no macOS frameworks required)
Resources/              sdef, Info.plist, entitlements, bundled presets
server/                 the Node widget engine, unmodified
Scripts/                build-runtime.sh, build-app.sh
```

`WijetiCore` stays AppKit-free so a Linux or Windows host becomes a new `HostPlatform`
implementation rather than a fork.

## Widget library

50 widgets ship in the bundle across 11 categories — System, Clock, Calendar, Weather,
Music, Media, Finance, Productivity, Social, Fun and Other — harvested from
[uebersicht-widgets](https://github.com/felixhageloh/uebersicht-widgets),
[Glass-Widgets-Uebersicht](https://github.com/msavox/Glass-Widgets-Uebersicht) and
[ubersicht-hud-dashboard](https://github.com/nambiropeter/ubersicht-hud-dashboard),
plus first-party Open-Meteo widgets.

Community widgets vary in age: some shell out to tools that no longer exist, so a given
one may render blank. That is a property of the widget, not the host — the library lists
them all and you remove the ones you do not want. Each preset's metadata lives in
`Resources/presets/Catalog.json`.

## Widgets

A widget is a folder containing `index.jsx` (or a single `.jsx` / `.coffee` / `.js` file):

```jsx
import { React, run } from "uebersicht";

export const refreshFrequency = 1000;
export const command = "date '+%Y-%m-%d %H:%M'";

export const render = ({ output }) => <div>{output}</div>;
```

`inBackground` puts a widget behind other applications; everything else renders on top.

## Credits

The widget engine in `server/` is Übersicht's, by
[Felix Hageloh](https://github.com/felixhageloh/uebersicht) — MIT licensed, and used
unmodified. Wijeti is an independent Swift reimplementation of the host application.
