# Contributing

1. `swift build` and `swift test` must pass (CI runs both on arm64 and x86_64).
2. Keep `Sources/WijetiCore` free of AppKit/SwiftUI imports; platform code goes in `WijetiMacOS`.
3. Adding a permission is one entry in `PermissionCatalog` plus its `Info.plist` usage key and
   entitlement; `PermissionCatalogTests` checks both.
4. Do not commit build output (`build/`, `dist/`, `.build/`) or DMGs.
5. Releases: bump `VERSION` / `BUILD_NUMBER`, run `Scripts/release.sh`.

Design history lives in [docs/design-notes](docs/design-notes).
