## Wijeti 0.2.1-beta.1

Widget Library and desktop layout fixes. Build this version with `Scripts/release.sh`, which
packages both architectures, refreshes the Sparkle feeds and publishes the GitHub release.

### Fixes
- **A missing widget library is recoverable.** The Library names the problem, shows the path it
  looked in, and offers **Choose Folder…**, **Restore Bundled Widgets**, **Copy Diagnostics** and
  **Reveal**. The chosen folder is remembered, and dropped again if it stops containing a
  catalog. When imported widgets still list, the same notice appears above the gallery.
- **Names are readable.** Cards, list rows and the inspector wrap widget names to two lines and
  keep the full name in the tooltip; status badges moved to the card footer.
- **Finding widgets takes less scrolling.** Every category in the sidebar carries a count, and an
  **All / On Desktop / Free to Add** filter sits beside the result count.
- **The preview pane tells you what it is doing.** A **Live preview** / **Loading** /
  **Unavailable** badge, and a failed preview explains itself with **Try Again**.
- **Destructive actions are named.** "Remove <widget> from Desktop…" replaces a bare Remove, and
  a confirmation still comes first.
- **Desktop widgets no longer collide on a fresh install.** The welcome card sits below the
  clock, the quote moved to the left rail, and the 8-ball and calendar sit clear of the system
  card, the day progress rows and each other.

### Known limitations
- Same as 0.2.0-beta.1: ad-hoc signed, not notarized; permissions may be re-requested after an
  update; widget management is still window-only.

## Wijeti 0.2.0-beta.1

Redesign update. **Ad-hoc signed, not notarized** — read [INSTALL.md](INSTALL.md) for the one-time
steps to open it safely. Download the build for your Mac: `arm64` for Apple Silicon, `x86_64` for
Intel. Requires macOS 15 or later.

### Highlights
- **New onboarding:** one screen — what Wijeti is, where widget management lives, straight into the
  Widget Library. No separate permissions or launch-at-login step; those live in Settings.
- **Settings overhaul:** sidebar search across every pane, Widgets pane is now a summary that opens
  the Library, General gained **Show Welcome Tour**, badges use the shared design tones.
- **Widget Library redesign:** adaptive grid/list with a shared design system, category sidebar that
  folds away on narrow windows, live preview pinned to a real frame, inspector-only per-widget
  controls, and a back control for compact layouts.
- **Shared design system:** `AppDesign.swift` gives every surface the same gutters, radii, tints,
  system surfaces, and status tones so Preferences, Library and onboarding read as one app.
- **Menu bar:** health indicator, Add Widgets, Refresh, Reload, Preferences, Check for Updates;
  Active Widgets visibility shortcut kept.

### Fixes
- Desktop widgets come back after the widget server restarts.
- Safer zip import; a crash-looping server backs off and gives up instead of spinning.
- Corrupt settings are moved aside instead of being overwritten.

### Known limitations
- Not notarized (see INSTALL.md); permissions may be re-requested after each update.
- No default reload interval setting (widgets set their own refresh rate).
- Intel build is tested under Rosetta only.
- A per-widget quick action from the desktop itself is the next step — widget management is still
  reachable only through the windows.
