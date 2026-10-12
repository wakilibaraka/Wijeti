import AppKit
import SwiftUI
import WebKit
import WijetiCore

// MARK: - Library window controller

/// The main widget library window: installed widgets on the left, the bundled library
/// in the middle, and a live preview of any preset on the right.
///
/// Nothing here is installed until the user taps Install, and the preview pane runs a
/// private throwaway server so the real widget directory, settings and running server are
/// never touched.
public final class WidgetLibraryWindow: NSWindowController, NSWindowDelegate {
    /// The shared model that owns the catalog, the installed list, the preview controller,
    /// and the install/import/refresh actions.
    public var model: WidgetLibraryModel!

    private var didShowWindow = false

    public init(model: WidgetLibraryModel) {
        self.model = model
        // The SwiftUI view is the window's content; the controller keeps the model alive.
        let view = WidgetLibraryView(model: model)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Widget Library"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Chrome: the sidebar's material runs to the top edge, so the title bar is only a
        // drag surface and the sidebar toggle.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        // The sidebar samples the desktop through the window, so the window itself must not
        // be opaque. The content and detail panes paint their own background, so the sidebar
        // is the only translucent surface.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.setContentSize(NSSize(width: 1180, height: 660))
        window.center()
    }

    /// The red close button closes the `NSWindow` directly, bypassing `close()` above, so the
    /// private preview server would otherwise keep running with the window hidden.
    @MainActor
    public func windowWillClose(_ notification: Notification) {
        model.stopPreview()
    }

    /// Loads the model before the window is on screen, then seeds a selection so the preview
    /// pane is never dead space.
    ///
    /// `WidgetLibraryModel.init` deliberately does not touch the disk, so without this the
    /// window opens with an empty catalog and an empty installed list — it only filled in
    /// after the user happened to trigger an action that called `reload()`.
    @MainActor
    public override func showWindow(_ sender: Any?) {
        model.reload()
        super.showWindow(sender)
        guard !didShowWindow else { return }
        didShowWindow = true
        model.autoSelectIfNeeded()
    }

    @MainActor
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @MainActor
    public override func awakeFromNib() {
        fatalError("WidgetLibraryWindow should not be loaded from a nib")
    }

    /// Public entry point used by the app delegate and the verification runner.
    /// Keeps the same shape as the v1 `show()` so callers do not need to change.
    @MainActor
    public func show() {
        NSApp.activate()
        showWindow(nil)
        model.resumePreview()
    }

    /// Stops the (private) preview server and tears down the scratch directories.
    @MainActor
    public func shutdown() {
        model.stopPreview()
    }

    /// Keep the window alive across close so reopening is instant.
    @MainActor
    public override func close() {
        // Match the v1 behaviour: stop the preview server, but leave the window object
        // alive so a later `show()` is cheap.
        model.stopPreview()
        window?.orderOut(nil)
    }

    // MARK: - Verification hooks (used by `--verify-presets`)

    /// Catalog ids in display order — the list `--verify-presets` walks.
    @MainActor
    public func bundledPresetIDs() -> [String] {
        model.catalog.presets.map(\.id)
    }

    /// Selects a preset in the library, which starts/updates the preview for it.
    @MainActor
    public func selectPreset(id: String) {
        guard let preset = model.catalog.presets.first(where: { $0.id == id }) else {
            NSLog("verify: unknown preset %@", id)
            return
        }
        model.select(preset)
    }

    /// Asks the preview page what it has rendered:
    /// `found` (the preset's own widget element), an error table, the page title
    /// (which carries `jserror:` for uncaught errors), and the visible text.
    @MainActor
    public func probePreview(
        completion: @escaping (Result<(found: Bool, error: Bool, title: String, text: String), Error>) -> Void
    ) {
        let serverID = model.previewServerWidgetID ?? ""
        let script = """
        (function () {
          var el = document.getElementById('\(serverID)');
          if (!el) {
            return JSON.stringify({found: false, error: false,
              title: document.title, text: '', count: document.querySelectorAll('.widget').length});
          }
          return JSON.stringify({found: true,
            // The server's ErrorDetails renders its code table with an *inline*
            // `border-collapse` style; widget tables (e.g. the calendar grid) use
            // emotion classes and carry no inline style, so this never false-positives.
            error: !!el.querySelector('table[style*="border-collapse"]'),
            title: document.title, text: (el.innerText || '').slice(0, 200), count: 1});
        })()
        """
        model.previewController.webViewController.webView.evaluateJavaScript(script) { value, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let raw = value as? String,
                      let data = raw.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    completion(.failure(NSError(
                        domain: "WijetiPreview",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "unreadable probe: \(value ?? "nil")"]
                    )))
                    return
                }
                completion(.success((
                    found: json["found"] as? Bool ?? false,
                    error: json["error"] as? Bool ?? false,
                    title: json["title"] as? String ?? "",
                    text: json["text"] as? String ?? ""
                )))
            }
        }
    }

    /// Snapshots the preview web view (no Screen Recording permission needed —
    /// it is an in-process `WKWebView` snapshot).
    @MainActor
    public func snapshotPreview(completion: @escaping (NSImage?) -> Void) {
        model.previewController.webViewController.snapshot(completion: completion)
    }

    /// Renders the whole library window (including the preview pane) to an image.
    @MainActor
    public func snapshotWindow(completion: @escaping (NSImage?) -> Void) {
        completion(snapshotWindowImage())
    }

    /// The same render, returned directly — used by `--capture-ui`.
    @MainActor
    public func snapshotWindowImage() -> NSImage? {
        WindowSnapshot.capture(window)
    }

    /// Chrome check for `--capture-ui` — logged, not eyeballed.
    @MainActor
    public var chromeSummary: String {
        WindowSnapshot.chromeSummary(of: window)
    }
}

/// Drives the library: what is installed, what is available, what just happened.
@MainActor
public final class WidgetLibraryModel: ObservableObject {
    public struct Installed: Identifiable, Equatable {
        public let id: String
        public var title: String
        public var visible: Bool
        public var inBackground: Bool
        public var onAllScreens: Bool
    }

    @Published public var installed: [Installed] = []
    @Published public var catalog: PresetCatalog = PresetCatalog(presets: [])
    /// Why the bundled library is empty, when it is empty for a reason other than
    /// "there are none". Set by `loadCatalog()` from the loader's own report.
    @Published public var catalogProblem: String?
    @Published public var search = ""
    @Published public var selectedCategory: String?
    @Published public var status = "" {
        didSet {
            guard status != oldValue, !status.isEmpty else { return }
            statusClearWork?.cancel()
            let message = status
            let work = DispatchWorkItem { [weak self] in
                // Only clear the message that scheduled this; a newer one keeps its own timer.
                if self?.status == message { self?.status = "" }
            }
            statusClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }
    private var statusClearWork: DispatchWorkItem?
    @Published public var busy = false
    /// Ids from the catalog that are already on disk, so their button reads "Installed".
    @Published public var installedPresetIDs: Set<String> = []
    /// The preset shown in the preview pane.
    @Published public var selectedPreset: Preset?
    /// Live status line for the preview pane ("Starting preview…", errors, …).
    @Published public var previewStatus = ""
    /// True once the preview page has loaded; until then the pane shows the status.
    @Published public var previewReady = false
    /// True while a drag is hovering over the window, for the drop-target affordance.
    @Published public var isDropTargeted = false
    /// Shows a one-shot confirmation/alert popup.
    @Published public var showPopup = false
    @Published public var popupTitle = ""
    @Published public var popupMessage = ""
    /// Popup button label for the action to run when dismissed.
    @Published public var popupActionLabel = ""
    @Published public var popupAction: (() -> Void)?
    /// Which installed-widget view is currently shown: the full list, or newest first.
    @Published public var showRecentFirst = false
    /// Last-seen timestamps used to sort the "recently installed" view.
    private var lastSeenAt: [String: Date] = [:]

    let previewController: WidgetPreviewController
    private let host: HostApp
    private let presetsDirectory: URL

    /// Built on demand rather than stored: the widget folder can change while the app runs, so
    /// a cached importer would keep writing into the folder the user just moved away from.
    private var importer: WidgetImporter {
        WidgetImporter(widgetDirectory: host.widgetDirectoryURL)
    }

    public init(host: HostApp, presetsDirectory: URL) {
        self.host = host
        self.presetsDirectory = presetsDirectory
        previewController = WidgetPreviewController(
            platform: host.platform,
            loginShell: { host.loginShell }
        )
        previewController.onStatus = { [weak self] text in
            self?.previewStatus = text
        }
        previewController.onReadyChange = { [weak self] ready in
            self?.previewReady = ready
        }
        // Read the catalog now, not on first show. The SwiftUI content is built as part of
        // this controller's window, so anything loaded only in `showWindow` is missing from
        // the render the user actually sees — which is how the library came up as
        // "0 widgets bundled" and only filled in after some later action triggered a reload.
        loadCatalog()
    }

    /// Reads `Catalog.json` and records why it was empty, if it was.
    func loadCatalog() {
        let report = PresetCatalog.loadReport(from: presetsDirectory) { NSLog("%@", $0) }
        catalog = PresetCatalog(presets: report.presets)
        catalogProblem = report.presets.isEmpty ? report.problem : nil
    }

    /// Where the library was read from, with the home directory abbreviated for display.
    public var libraryDirectoryDisplayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = presetsDirectory.canonicalPathURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Opens the library folder so a broken install can be inspected where it actually is.
    public func revealLibraryDirectory() {
        let directory = presetsDirectory.canonicalPathURL
        let target = FileManager.default.fileExists(atPath: directory.path)
            ? directory
            : directory.deletingLastPathComponent()
        host.platform.revealInFinder(target)
    }

    // MARK: - Preview selection

    /// Selects a preset and shows it in the preview pane. Nothing is installed.
    public func select(_ preset: Preset) {
        selectedPreset = preset
        previewController.show(preset, from: presetsDirectory)
    }

    /// First run of the window: pick something so the pane is never dead space.
    public func autoSelectIfNeeded() {
        guard selectedPreset == nil, let first = catalog.presets.first else { return }
        select(first)
    }

    /// Re-issues the current selection after a stop (the window was closed).
    public func resumePreview() {
        guard let preset = selectedPreset else { return }
        previewController.show(preset, from: presetsDirectory)
    }

    public func stopPreview() {
        previewController.stop()
    }

    /// The widget id the preview server derives from the selected preset's entry file
    /// (mirrors `server/src/resolveWidget.js`), used to probe the rendered element.
    public var previewServerWidgetID: String? {
        guard let preset = selectedPreset else { return nil }
        let base = presetsDirectory.appendingPathComponent(preset.id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else {
            return nil
        }
        let entry = isDirectory.boolValue ? base.appendingPathComponent(preset.entry) : base
        return WidgetImporter.widgetID(for: entry, root: presetsDirectory)
    }

    /// Re-reads the bundled catalog and everything that derives from the server's state.
    /// Reserved for the points where the catalog itself can have changed.
    public func reload() {
        loadCatalog()
        refreshInstalledFromHost()
    }

    /// Rebuilds only the parts that come from the running server rather than from disk.
    ///
    /// Cheap enough to run on every state poll — `reload()` also re-reads `Catalog.json` and
    /// stats every preset file, so it is the wrong thing to call from a 1 Hz timer. Nothing
    /// here touches the user's filters or selection, so it never disturbs what is on screen.
    public func refreshInstalledFromHost() {
        // installed widgets come from the running server's state
        installed = host.widgetIDs.compactMap { id in
            guard host.widgetDirectoryURL.appendingPathComponent(id).path != "/" else { return nil }
            let settings = host.settings(for: id)
            return Installed(
                id: id,
                title: id.replacingOccurrences(of: "-", with: " "),
                visible: !settings.hidden,
                inBackground: settings.inBackground,
                onAllScreens: settings.showOnAllScreens
            )
        }
        installedPresetIDs = Set(
            catalog.presets.map(\.id).filter { widgetInstalled($0) }
        )
        // Seed the recency tracker so "recently installed" is meaningful after a reload.
        let now = Date()
        for id in host.widgetIDs {
            lastSeenAt[id] = lastSeenAt[id] ?? now
        }
    }

    // MARK: - Library

    /// Categories for the filter chip bar (in preferred order).
    public var categories: [String] {
        PresetCatalog.preferredOrder.filter { category in catalog.presets.contains { $0.category == category } }
    }

    /// All presets, optionally filtered by category and search. Flat list — no section
    /// headers, so the filter chips at the top are the only category UI (no duplication).
    public var filteredPresets: [Preset] {
        var presets = catalog.presets
        if let selectedCategory {
            presets = presets.filter { $0.category == selectedCategory }
        }
        if !search.isEmpty {
            let needle = search.lowercased()
            presets = presets.filter {
                $0.title.lowercased().contains(needle)
                    || $0.description.lowercased().contains(needle)
                    || $0.id.lowercased().contains(needle)
            }
        }
        return presets.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Installed presets ordered by install time, newest first.
    public var recentlyInstalledPresets: [Preset] {
        installedPresetIDs.compactMap { id in
            catalog.presets.first(where: { $0.id == id })
        }.sorted { left, right in
            (lastSeenAt[left.id] ?? .distantPast) > (lastSeenAt[right.id] ?? .distantPast)
        }
    }

    /// The running server's entry for a bundled preset. Server ids are derived from the path
    /// (`Clock.widget` → `Clock-widget-index-jsx`), so the preset id has to go through the same
    /// derivation before it can be matched.
    public func installedWidget(for preset: Preset) -> Installed? {
        let base = WidgetImporter.widgetID(
            for: host.widgetDirectoryURL.appendingPathComponent(preset.id),
            root: host.widgetDirectoryURL
        )
        return installed.first { $0.id == base || $0.id.hasPrefix(base + "-index-") }
    }

    public func isInstalled(_ preset: Preset) -> Bool { installedPresetIDs.contains(preset.id) }

    /// Copies a bundled preset into the widget directory and reveals it.
    public func install(_ preset: Preset) {
        let source = presetsDirectory.appendingPathComponent(preset.id)
        guard bundledPresetExists(preset.id) else {
            status = "\(preset.title) is missing from the bundled library."
            return
        }
        do {
            let result = try importer.importWidgets(at: [source])
            if result.installed.isEmpty {
                status = "\(preset.title) is already installed."
            } else {
                status = "Installed \(preset.title)."
                // Newly installed widgets default to visible; make that explicit rather
                // than relying on the server's defaults matching ours.
                for id in result.installed { host.updateSettings(id) { $0.hidden = false } }
                host.reloadWidgets()
                markInstalled(preset)
            }
            for failure in result.failures {
                status = "\(preset.title): \(failure.reason)"
            }
            reload()
        } catch {
            status = "Could not install \(preset.title): \(error.localizedDescription)"
        }
    }

    /// Shows a confirmation popup before installing.
    public func confirmInstall(_ preset: Preset) {
        popupTitle = "Install \(preset.title)?"
        popupMessage = "This will add \"\(preset.title)\" to your desktop widgets.\n\nIt will be visible and shown on all screens by default."
        popupActionLabel = "Install"
        popupAction = { [weak self] in self?.doInstall(preset) }
        showPopup = true
    }

    func doInstall(_ preset: Preset) {
        showPopup = false
        install(preset)
    }

    /// Shows a confirmation popup before removing an installed widget.
    public func confirmRemove(_ widget: Installed) {
        popupTitle = "Remove \(widget.title)?"
        popupMessage = "This will remove \"\(widget.title)\" from your widgets and stop it from running. This cannot be undone."
        popupActionLabel = "Remove"
        popupAction = { [weak self] in self?.doRemove(widget) }
        showPopup = true
    }

    /// Shows a confirmation popup before removing a preset that is already installed.
    public func confirmRemoveInstalled(_ preset: Preset) {
        guard let widget = installed.first(where: { $0.id == preset.id }) else { return }
        popupTitle = "Remove \(widget.title)?"
        popupMessage = "This will remove \"\(widget.title)\" from your widgets and stop it from running. This cannot be undone."
        popupActionLabel = "Remove"
        popupAction = { [weak self] in self?.doRemove(widget) }
        showPopup = true
    }

    /// Shows a confirmation popup before disabling a widget without deleting it.
    public func confirmDisable(_ widget: Installed) {
        guard !widget.visible else { return }
        popupTitle = "Disable \(widget.title)?"
        popupMessage = "\"\(widget.title)\" will be hidden from your desktop until you turn it back on. It stays installed."
        popupActionLabel = "Disable"
        popupAction = { [weak self] in self?.doDisable(widget) }
        showPopup = true
    }

    private func doDisable(_ widget: Installed) {
        showPopup = false
        setVisible(false, for: widget.id)
    }

    private func doRemove(_ widget: Installed) {
        showPopup = false
        remove(widget)
    }

    /// Installs several presets at once — the "Add the essentials" path.
    public func install(_ presets: [Preset]) {
        var installed = 0
        var failed: [String] = []
        for preset in presets {
            guard bundledPresetExists(preset.id) else {
                failed.append(preset.title)
                continue
            }
            if let result = try? importer.importWidgets(at: [presetsDirectory.appendingPathComponent(preset.id)]),
               !result.installed.isEmpty {
                installed += 1
                for id in result.installed { host.updateSettings(id) { $0.hidden = false } }
            } else {
                failed.append(preset.title)
            }
        }
        status = failed.isEmpty
            ? "Added \(installed) widget\(installed == 1 ? "" : "s")."
            : "Added \(installed); could not add \(failed.joined(separator: ", "))."
        host.reloadWidgets()
        reload()
    }

    // MARK: - Bring your own

    /// Installs whatever the user dropped onto the window. Handles folders, .jsx/.js/.coffee
    /// files, and .zip archives (unpacked off the main thread into a scratch directory first).
    public func importDropped(_ urls: [URL]) {
        let usable = urls.filter { importer.canImport($0) || $0.pathExtension.lowercased() == "zip" }
        guard !usable.isEmpty else {
            status = "Drop a widget folder, a .jsx / .coffee / .js file, or a .zip archive."
            return
        }
        let zips = usable.filter { $0.pathExtension.lowercased() == "zip" }
        let direct = usable.filter { $0.pathExtension.lowercased() != "zip" }
        guard !zips.isEmpty else {
            finishImport(direct, scratch: [])
            return
        }
        status = "Unpacking…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var extracted: [URL] = []
            var scratch: [URL] = []
            var failure: String?
            for zip in zips {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Wijeti-Zip-\(UUID().uuidString)", isDirectory: true)
                scratch.append(directory)
                do {
                    extracted += try WidgetArchive().extract(zip, into: directory)
                } catch {
                    failure = "\(zip.lastPathComponent): \(error.localizedDescription)"
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure {
                    scratch.forEach { try? FileManager.default.removeItem(at: $0) }
                    self.status = "Could not install \(failure)"
                    return
                }
                self.finishImport(direct + extracted, scratch: scratch)
            }
        }
    }

    private func finishImport(_ urls: [URL], scratch: [URL]) {
        defer { scratch.forEach { try? FileManager.default.removeItem(at: $0) } }
        do {
            let result = try importer.importWidgets(at: urls)
            var parts: [String] = []
            if !result.installed.isEmpty {
                parts.append("Installed \(result.installed.count)")
                for id in result.installed { host.updateSettings(id) { $0.hidden = false } }
            }
            if !result.skipped.isEmpty { parts.append("already had \(result.skipped.joined(separator: ", "))") }
            if !result.failures.isEmpty { parts.append("skipped \(result.failures.first?.reason ?? "some files")") }
            status = parts.joined(separator: " · ")
            host.reloadWidgets()
            reload()
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Opens a panel so the user can pick a folder or a bare widget file.
    public func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        panel.prompt = "Install"
        panel.message = "Choose a widget folder, or a .jsx / .coffee / .js file."
        guard panel.runModal() == .OK else { return }
        importDropped(panel.urls)
    }

    // MARK: - Installed widgets

    public func setVisible(_ visible: Bool, for id: String) {
        host.updateSettings(id) { $0.hidden = !visible }
        reload()
    }

    public func setInBackground(_ value: Bool, for id: String) {
        host.updateSettings(id) { $0.inBackground = value }
        reload()
    }

    /// How many installed widgets are currently visible — drives the section badge.
    public var visibleCount: Int {
        installed.filter(\.visible).count
    }

    /// Makes every installed widget visible now. A thin wrapper over `HostApp` so the menu
    /// bar, the library and AppleScript all share one implementation of the loop.
    public func enableAllVisibleNow() {
        host.enableAllVisibleNow()
        reload()
    }

    /// Hides every installed widget now.
    public func disableAllNow() {
        host.disableAllNow()
        reload()
    }

    public func setOnAllScreens(_ value: Bool, for id: String) {
        host.updateSettings(id) { $0.showOnAllScreens = value }
        reload()
    }

    // MARK: - Source on disk

    /// The preset's folder, or its bare `.jsx` file when the preset is a single file.
    public func sourceRoot(for preset: Preset) -> URL {
        presetsDirectory.appendingPathComponent(preset.id)
    }

    /// The file an editor should open: the entry file inside a widget folder, or the preset
    /// file itself for a bare `.jsx`.
    public func sourceFile(for preset: Preset) -> URL {
        let base = sourceRoot(for: preset)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue, !preset.entry.isEmpty else { return base }
        return base.appendingPathComponent(preset.entry)
    }

    /// Shows a bundled widget's source in Finder.
    public func revealSource(for preset: Preset) {
        let url = sourceRoot(for: preset)
        guard FileManager.default.fileExists(atPath: url.path) else {
            status = "\(preset.title) is no longer on disk."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens a bundled widget's entry file in whatever the user has set as their editor.
    ///
    /// A stock macOS has no handler for `.jsx`, so failing here is a normal outcome and is
    /// reported rather than swallowed.
    public func openSource(for preset: Preset) {
        let target = sourceFile(for: preset)
        guard FileManager.default.fileExists(atPath: target.path) else {
            status = "\(preset.title) is no longer on disk."
            return
        }
        if !NSWorkspace.shared.open(target) {
            status = "Nothing is set to open \(target.lastPathComponent) — use Reveal and pick an app."
        }
    }

    /// Shows an installed widget in Finder.
    public func revealOnDisk(_ widget: Installed) {
        guard let folder = folderName(forServerID: widget.id) else {
            status = "Could not locate \(widget.title) on disk."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([
            host.widgetDirectoryURL.appendingPathComponent(folder)
        ])
    }

    public func remove(_ widget: Installed) {
        // The id the server uses is the path with separators turned into dashes, so undo it.
        guard let folder = folderName(forServerID: widget.id) else {
            status = "Could not locate \(widget.title) on disk."
            return
        }
        guard importer.removeWidget(named: folder) != nil else {
            status = "Could not remove \(widget.title)."
            return
        }
        status = "Removed \(widget.title)."
        host.reloadWidgets()
        reload()
    }

    public func markInstalled(_ preset: Preset) {
        lastSeenAt[preset.id] = Date()
    }

    public func refreshAll() {
        host.refreshWidgets()
        status = "Refreshed."
    }

    // MARK: - Helpers

    /// True when the bundled preset exists in the presets directory (library source).
    private func bundledPresetExists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: presetsDirectory.appendingPathComponent(id).path)
    }

    /// True when a widget is already installed (lives in the widget directory).
    private func widgetInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(
            atPath: host.widgetDirectoryURL.appendingPathComponent(id).path
        )
    }

    /// Widget ids are lossy (`-` for both separators), so only folders that actually
    /// produce this id are accepted — no guessing.
    private func folderName(forServerID id: String) -> String? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: host.widgetDirectoryURL.path
        )) ?? []
        return contents.first {
            WidgetImporter.widgetID(
                for: host.widgetDirectoryURL.appendingPathComponent($0),
                root: host.widgetDirectoryURL
            ) == id
        }
    }
}
