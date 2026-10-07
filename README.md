# ⚡ Wijeti

A native Swift desktop widget host for macOS — the spirit of
[Übersicht](https://github.com/felixhageloh/uebersicht) rewritten from scratch in Swift,
with a modern menu bar, a first-launch onboarding, and a Settings panel built the way
Apple ships settings surfaces today.

## What's new in 0.1.0

- **Library without Finder.** The Widget Library (`⌘L`, or the tray) lists bundled widgets
  by category with search, installs them in one click, and lets you toggle each one on and
  off. Drag a widget folder onto the window, or use **Install Your Own…**, and it lands
  in the right place — you never need to know the path.
- **Modern menu bar.** A compact status item with a categorized menu, live status text, and
  keyboard shortcuts. Refresh, reload, open the library, open the widgets folder, visit the
  widget gallery, Preferences, or Quit — all from one place.
- **Onboarding and Settings, the iOS-style way.** First-launch onboarding leads with SF
  Symbols and a vertical feature list, with a flat call-to-action button pinned to the bottom.
  Settings uses inset-grouped sections with small icon badges that telegraph what each group
  controls.
- **Permissions and data sources.** One pane lists the permissions widgets may need
  (Location, Full Disk Access, Automation, Notifications), shows the real status, and opens
  the exact System Settings pane. The weather widget uses [Open-Meteo](https://open-meteo.com/),
  which needs no API key.
- **AppleScript.** `refresh`, `reload`, `count widgets`, and `every widget` with
  `id` / `hidden` / `showOnMainScreen` / `showOnAllScreens`.
- **Hybrid widget platform, in progress.** Work has begun on a second widget file format
  (plain HTML/CSS/JS packages with typed variables stored in the system Keychain), an in-app
  code-editor studio with live preview, and a manifest designed to be portable to
  iOS / WidgetKit later. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Requirements

- macOS 15 or later, Apple Silicon (arm64)
- Xcode 16+ (`xcode-select --switch /Applications/Xcode.app`) — the `sdef` / `osacompile`
  tooling needs the full Xcode, not just the Command Line Tools.

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

`build-app.sh` ad-hoc signs the bundle with `com.apple.security.cs.disable-library-validation`.
That entitlement is mandatory: without it the bundled Node runtime aborts on `dlopen` of
`fsevents.node` with a Team-ID mismatch, which costs three ports' worth of confusion.

## First launch

The first time you open Wijeti you'll see the onboarding window. It explains what Wijeti
does in a few short feature cards with SF Symbols, and ends with a big flat
**Get Started** button pinned to the bottom. After that, the menu bar icon is your home base.

## Layout

```
Sources/WijetiCore/     portable models + server supervision — no AppKit import
Sources/WijetiMacOS/    AppKit host: windows, tray, preferences, onboarding, web views
Sources/WijetiApp/      @main executable, options parsing, snapshot proof
Tests/WijetiCoreTests/  unit tests (no macOS frameworks required)
Resources/              sdef, Info.plist, entitlements, bundled presets, icon
server/                 the Node widget engine, unmodified
Scripts/                build-runtime.sh, build-app.sh
docs/                   roadmap and design notes
```

`WijetiCore` stays AppKit-free so a Linux or Windows host becomes a new `HostPlatform`
implementation rather than a fork.

## Widgets

A widget is a folder containing `index.jsx` (or a single `.jsx` / `.coffee` / `.js` file):

```jsx
import { React, run } from "uebersicht";

export const refreshFrequency = 1000;
export const command = "date '+%Y-%m-%d %H:%M'";

export const render = ({ output }) => <div>{output}</div>;
```

`inBackground` puts a widget behind other applications; everything else renders on top.

If an old QtWidgets-based widget renders blank, open an issue and include the widget's
folder name and the macOS error log.

### Bundled

Bundled presets are hand-written, curated widgets. They're meant to be a starting point —
copy any of them and make it yours.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘L` | Show the Widget Library |
| `⌘,` | Show Preferences |
| `⌘Q` | Quit Wijeti (from the menu bar) |

## First release DMG

The first release ships as a `.dmg` for drag-and-drop install. From the built
`build/Wijeti.app`:

```sh
hdiutil create -volname Wijeti -srcfolder build/Wijeti.app \
  -ov -format UDZO Wijeti-0.1.0-arm64.dmg
```

That produces `Wijeti-0.1.0-arm64.dmg` in the repository root. Open it to drag
Wijeti into `/Applications`.

## Reproducible builds

- `Scripts/build-runtime.sh` produces `server/release` — the portable Node widget engine
  that `Wijeti.app` embeds.
- `Scripts/build-app.sh` builds the Swift binary, assembles the bundle, and ad-hoc signs it.
- Run `swift test` from the package root before releasing; the test suite includes a
  catalog-consistency test that asserts the bundled catalog, folder names, and entry files
  all agree.

## Architecture

- **Widget engine.** The `server/` directory is Übersicht's widget runtime, used unchanged
  and running as a separate process. Wijeti talks to it over a local socket.
- **Swift side.** `WijetiCore` owns the model, the server supervisor, the settings store, and
  the preset catalog. `WijetiMacOS` is the AppKit host: tray, windows, web views, preferences,
  onboarding. `WijetiApp` is the executable entry point and the AppleScript delegate.
- **Scripting.** The AppleScript dictionary is `Resources/Wijeti.sdef`. Two rules learned the
  hard way are load-bearing there: command codes must be exactly eight characters, and classes
  and properties need real Cocoa bindings.

## Roadmap

See [docs/ROADMAP.md](docs/ROADMAP.md). The near-term work is the second widget format
(HTML packages with typed variables), the in-app code studio, and portability groundwork for
iOS / other systems later.

## Credits

The widget engine in `server/` is Übersicht's, by Felix Hageloh — MIT licensed, and used
unchanged. Wijeti is an independent Swift reimplementation of the host application.

## License

`server/` and the upstream widget metadata are GPL-3.0 — the server is a GPL-3.0 module, and
GPL code cannot be statically linked into a non-GPL program without exposing the link. Here
the server runs as a separate process. The rest of Wijeti is MIT.
