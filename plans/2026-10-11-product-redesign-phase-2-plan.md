# 2026-10-11 Product Redesign (Phase 2: Onboarding-First Launch + Library Polish) — Plan

## Context
Phase 1 refactored the Widget Library's filtering/installed UX, added a menu-bar Active Widgets list, and made onboarding dismiss into the library. Phase 2 is the visual/experience pass the user asked for: make onboarding the real first-launch centerpiece (centered, colorful, stepped, explanatory), then make the Widget Library match a cleaner macOS-native presentation without disturbing the engine.

## Goals
- Onboarding becomes a polished, colorful, stepped introduction that:
  - appears centered on screen,
  - explains what the app does,
  - includes a permissions/data-sources step,
  - feels like a typical modern onboarding screen rather than a flat text card.
- Widget Library gets a cleaner look and clearer information architecture:
  - less duplicate category noise,
  - more readable installed-widget rows,
  - clearer remove/disable distinction,
  - better empty states,
  - menu-bar Active Widgets list stays useful.
- Preserve existing engine behavior: `WKWebView` preview bridging, file-system state, server lifecycle, window pinning, AppleScript bridge, and settings flow should not be altered unless explicitly required.

## What is already in place
- Onboarding window exists and dismisses into the library.
- Widget Library already has: search, category chips, installed section, library list, recent-first section, preview pane, remove/disable popups, and Active Widgets menu.
- PresetCatalog already owns category order and grouping.

## Execution sequence
### 1. Onboarding overhaul (centerpiece)
- Restructure onboarding as a stepped experience:
  - welcome/what Wijeti is,
  - library/adding widgets,
  - permissions and data sources (location, Full Disk Access, Automation, notifications, weather/open-meteo note),
  - final step that dismisses and opens the library.
- Center the onboarding window on the main screen and keep it visually lively:
  - use color, iconography, and clear step indicators,
  - keep typography consistent with macOS conventions,
  - make the primary action prominent.
- Keep the onboarding dismiss flag behavior (`OnboardingDidComplete`) and the post-dismiss library-open behavior already wired.

### 2. Permission/data-source step
- Surface the key permissions the app actually depends on, with plain-language explanations.
- Prefer best-effort probing/status where the app already has it; do not invent new permission machinery unless needed.
- Link or direct users to the relevant System Settings area when a permission is missing.

### 3. Widget Library polish
- Tighten spacing/typography across the library pane and preview pane.
- Make installed rows easier to scan: clearer title, clearer status, clearer action buttons.
- Keep "Remove" and "Disable" visually and semantically distinct.
- Reduce redundant category display: if categories appear as filter chips, avoid repeating them as section headers inside the same list.
- Improve empty states for:
  - no bundled widgets,
  - no matching filter,
  - no installed widgets,
  - no selection in the preview pane.

### 4. Verification
- Build and check for compile errors.
- Reinstall to `/Applications/Wijeti.app`.
- Launch a fresh instance and confirm:
  - onboarding appears centered and stepped,
  - onboarding explains the app and includes permissions,
  - dismissing onboarding opens the library,
  - library still filters, installs, previews, removes/disables, and shows active widgets in the menu bar.

## Out of scope
- Full glassmorphism/vibrancy rewrite beyond what helps readability.
- Settings window modeless rewrite (later phase).
- Engine/server changes unless something blocks the UX pass.

## Risks
- Overcomplicating onboarding steps can make the flow feel slow; keep it short and scannable.
- Permissions probing can be noisy if over-reported; be conservative and accurate.
- Library polish should not reintroduce the duplicate-category problem Phase 1 fixed.

## Acceptance criteria
- Onboarding is centered, colorful, stepped, and explanatory, including permissions/data sources.
- Dismissing onboarding opens the Widget Library.
- Widget Library looks cleaner, with no redundant category duplication and clear remove/disable distinction.
- Menu-bar Active Widgets still lists visible widgets.
- App builds, installs, launches cleanly on a fresh instance, and the above is verifiable.
