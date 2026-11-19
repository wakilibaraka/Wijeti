# Changelog

## 0.2.1-beta.1

Widget Library and desktop layout fixes.

- A broken library is recoverable: the error state names the problem, shows the path it looked
  in, and offers **Choose Folder…**, **Restore Bundled Widgets**, **Copy Diagnostics** and
  **Reveal**. A chosen folder is remembered, and is ignored again if it stops containing a
  catalog. The same notice appears above the gallery when imported widgets still list. In a
  packaged app the bundled library lives inside the signed bundle, so Restore copies it into
  `~/Library/Application Support/Wijeti/Library` and reads the library from there.
- `--restore-presets` runs that recovery headlessly and logs the result, so a packaged build can
  prove the path works without a mouse.
- Widget names no longer truncate: cards, list rows and the inspector wrap to two lines with the
  full name in the tooltip, and status badges moved to the card footer so names get the row.
- Finding widgets: a count beside every category in the sidebar, and an **All / On Desktop /
  Free to Add** filter next to the result count.
- The preview pane reports its state — **Live preview**, **Loading**, **Unavailable** — and a
  failed preview explains itself with **Try Again**.
- Destructive actions are named: **Remove <widget> from Desktop…** in menus and the inspector,
  instead of a bare **Remove** or an unlabelled bin beside the status badge.
- Bundled presets no longer overlap on a fresh install: the welcome card moved below the clock,
  the quote joined the left rail, and the 8-ball and calendar moved clear of their neighbours.

## 0.2.0-beta.1
See [RELEASE_NOTES.md](RELEASE_NOTES.md).

## 0.1.0-beta.1
See [RELEASE_NOTES.md](RELEASE_NOTES.md).
