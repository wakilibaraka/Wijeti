## Wijeti 0.1.0-beta.1

First public beta. **Ad-hoc signed, not notarized** — read [INSTALL.md](INSTALL.md) for the one-time
steps to open it safely. Download the build for your Mac: `arm64` for Apple Silicon, `x86_64` for
Intel. Requires macOS 15 or later.

### Highlights
- Redesigned Widget Library: grid or list, foldable categories, live preview, multi-select with bulk
  show/hide, placement, category and remove.
- Add your own widgets (.zip, folder, .jsx/.js/.coffee, .html), then name and categorize them.
- Permissions that cover what widgets actually need (Automation per app, Calendars, Camera, Bluetooth,
  Full Disk, …) with live status and one-click prompts.
- New onboarding, Settings (General / Widgets / Permissions / Advanced) and a menu bar with a health
  indicator.
- Automatic updates (Sparkle) with signed downloads.

### Fixes
- Desktop widgets now come back after the widget server restarts.
- Safer zip import; crash-looping server backs off and gives up instead of spinning.
- Corrupt settings are moved aside instead of overwritten.

### Known limitations
- Not notarized (see INSTALL.md); permissions may be re-requested after each update.
- No default reload interval setting (widgets set their own refresh rate).
- Intel build is tested under Rosetta only.
