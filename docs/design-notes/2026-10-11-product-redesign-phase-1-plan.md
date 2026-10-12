# 2026-10-11 Product Redesign (Phase 1: Layout Overhaul) — Plan

## Scope
This plan covers the first redesign phase for Wijeti's macOS native widget engine: a **wireframe-level layout overhaul** of the main manager UI. The goal is to restructure how the app presents its core surfaces — widget library, preview, and installed-widget management — so they align with a modern macOS presentation model (sidebar-driven navigation, clear visual hierarchy, better separation between "what's installed" and "what's available"). No backend engine, window-pinning logic, or file-system watcher behavior is in scope for this phase.

## Objectives
- Replace the existing merged "Your widgets + Library catalog" left pane with a clearer two-section layout:
  - a top **Installed widgets** section (your widgets, with visibility/background/screens controls and remove/disable actions),
  - a lower **Library** section (bundled catalog, searchable, category-filterable, non-exclusive filtering so selecting one category doesn't hide the others from the user's mental model).
- Make the **Preview** pane more useful: wider, with clearer install/remove/disable state differentiation, and a working "Preview" action from the installed-widgets list.
- Remove duplicate category display (no category headers repeated both in the filter row and in the list body).
- Clean up the look: consistent spacing, clearer affordances, less noisy status text, better empty states.
- Add a menu-bar "Active Widgets" list so the tray shows what is currently visible.
- After onboarding dismiss, automatically open the widgets library (first-launch path ends on the library, not back on the desktop).

## What is already on disk (from prior edits)
Some of the above is already partly implemented in the current working tree:
- `WidgetLibraryWindow.swift` already has a merged left pane and a `showRecentFirst` toggle, `installedSection`, `libraryList`, and category chips.
- `TrayMenuController.swift` already has an "Active Widgets" submenu wired to `refreshActiveWidgets()`.
- `OnboardingWindow.swift` already dismisses and then calls `openLibraryAfterOnboarding()`.
- `PresetCatalog.swift` already owns category ordering (`preferredOrder`) and grouping.

What still needs attention in this phase:
- The "Preview" button in the installed-widget row must actually drive the preview pane selection (it is currently wired to `model.select(preset)`, but the surrounding UX still feels incomplete because the preview pane's "Install/Remove" actions and the library row's "Add/Installed" actions need to be visually and behaviorally distinct).
- Filtering UX: category chips should work as filters while leaving the rest of the library discoverable; the "Recent" view should be an extra lens, not a mode that hides categories.
- Remove vs Disable must be unambiguous everywhere they appear (installed list, library row when already installed, preview pane when already installed).
- The menu-bar active-widgets list should reflect visibility state accurately and stay in sync with state changes.
- Onboarding should reliably open the library after dismiss.

## Implementation approach
1. **Consolidate the model actions first.** Ensure `WidgetLibraryModel` has clear, well-named operations for:
   - preview a preset (`select`),
   - install a preset,
   - remove an installed widget,
   - disable/enable an installed widget,
   - toggle visibility, background, and all-screens placement.
   The UI should call these and not duplicate their logic.
2. **Redesign the left pane layout** so the installed section and the library section are visually separate but co-located, with the library section being the catalog backed by `filteredPresets` and the category chips acting as filters (not as a separate navigational mode that erases the rest of the view).
3. **Make the Recent filter an additive view.** When "Recent" is selected, show recently installed presets in a clearly labeled sub-section while still allowing the user to switch categories and search normally.
4. **Differentiate actions in the UI text and icons:**
   - "Remove" = delete the widget from disk / stop running,
   - "Disable" = hide it without deleting,
   - "Enable" = reverse a disable.
   Use distinct labels/icons/tooltips so a user can tell them apart in both the installed list and the preview pane.
5. **Wire the installed-widget "Preview" button** to select the matching catalog preset in the preview pane. If there is no matching catalog preset, the button should still do something sensible (e.g., select the installed widget's counterpart if available, or show a short status), not silently do nothing.
6. **Update the tray menu** so "Active Widgets" lists visible widgets and updates on state changes.
7. **Verify onboarding flow** ends with the library opening.
8. **Build, reinstall to `/Applications/Wijeti.app`, clear the app's support data for a fresh instance, and run it.** Then functionally verify:
   - first-launch onboarding appears and dismisses to the library,
   - library shows bundled widgets and categories,
   - category filtering works without hiding the rest of the UI unnecessarily,
   - "Recent" shows newly installed widgets,
   - preview button from "Your widgets" works,
   - remove and disable behave differently,
   - menu-bar active widgets list updates.

## Acceptance criteria (Phase 1)
- The main library window opens with a clear installed section and a catalog section; no duplicate category headers.
- Category chips filter the catalog; selecting a category does not make the rest of the library disappear in a way that forces the user to re-navigate.
- "Recent" view shows newest-installed first and is clearly labeled.
- Preview button in "Your widgets" actually previews the widget.
- Remove and Disable are distinguishable in the UI and do different things.
- Menu bar lists active widgets and updates.
- Onboarding opens the library after dismiss.
- App builds, installs, launches cleanly on a fresh instance, and the above behaviors are verifiable by running the app.

## Out of scope for this phase
- Full glassmorphism/vibrancy pass beyond what is needed to make the layout readable and clean.
- Code editor or widget authoring UI.
- Settings window modeless rewrite (deferred to a later phase).
- Any change to the widget server, dispatch.js, or file-system watcher behavior.

## Risks
- The current `filteredPresets` + `showRecentFirst` design may already be close to the desired behavior; the main risk is over-engineering the filter UX instead of polishing what exists.
- If the preview server/controller has quirks, "Preview" from the installed list may need careful wiring to avoid selecting the wrong preset or showing an empty preview.
- Menu-bar active-widget refresh must not fight with the existing state-polling lifecycle.

## Sequence
1. Read and reconcile the current `WidgetLibraryWindow.swift`, `TrayMenuController.swift`, `OnboardingWindow.swift`, and `PresetCatalog.swift` diffs.
2. Make the model/UI changes described above.
3. Build and fix any compile errors.
4. Reinstall and run a fresh instance.
5. Verify behaviors manually.
6. Commit and push.
