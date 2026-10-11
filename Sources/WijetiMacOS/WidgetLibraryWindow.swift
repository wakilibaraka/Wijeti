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
public final class WidgetLibraryWindow: NSWindowController {
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
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        window.conditionalSetContentSize(width: 1180, height: 660)
    }

    /// First show: seed a selection so the preview pane is never dead space.
    @MainActor
    public override func showWindow(_ sender: Any?) {
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
        NSApp.activate(ignoringOtherApps: true)
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
        guard let view = window?.contentView else {
            completion(nil)
            return
        }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds)
        else {
            completion(nil)
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        completion(image)
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
    @Published public var search = ""
    @Published public var selectedCategory: String?
    @Published public var status = ""
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
    private let importer: WidgetImporter
    private let presetsDirectory: URL

    public init(host: HostApp, presetsDirectory: URL) {
        self.host = host
        self.presetsDirectory = presetsDirectory
        self.importer = WidgetImporter(widgetDirectory: host.widgetDirectoryURL)
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

    public func reload() {
        catalog = PresetCatalog.load(from: presetsDirectory)
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

    fileprivate func doInstall(_ preset: Preset) {
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
        for preset in presets where !bundledPresetExists(preset.id) {
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

    // MARK: - Bring your own    /// Installs whatever the user dropped onto the window. Handles folders, .jsx/.js/.coffee
    /// files, and .zip archives (extracted to a temp dir first).
    public func importDropped(_ urls: [URL]) {
        let usable = urls.filter { importer.canImport($0) || $0.pathExtension.lowercased() == "zip" }
        guard !usable.isEmpty else {
            status = "Drop a widget folder, a .jsx / .coffee / .js file, or a .zip archive."
            return
        }
        do {
            var allURLs: [URL] = []
            for url in usable {
                if url.pathExtension.lowercased() == "zip" {
                    if let extracted = try? extractZip(url) {
                        allURLs.append(contentsOf: extracted)
                    } else {
                        status = "Could not extract \(url.lastPathComponent)."
                        return
                    }
                } else {
                    allURLs.append(url)
                }
            }
            let result = try importer.importWidgets(at: allURLs)
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

    /// Extracts a .zip archive to a temp directory and returns the paths of its contents.
    private func extractZip(_ zipURL: URL) throws -> [URL] {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wijeti-Zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", tempDir.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "WijetiZip", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "unzip failed"])
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        // If the zip contained a single top-level folder, use its contents directly.
        if contents.count == 1,
           let first = contents.first(where: { name in
               var isDir: ObjCBool = false
               return FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
           }) {
            return [tempDir.appendingPathComponent(first)]
        }
        return contents.map { tempDir.appendingPathComponent($0) }
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

    public func setOnAllScreens(_ value: Bool, for id: String) {
        host.updateSettings(id) { $0.showOnAllScreens = value }
        reload()
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

// MARK: - View

struct WidgetLibraryView: View {
    @ObservedObject var model: WidgetLibraryModel

    var body: some View {
        HSplitView {
            libraryPane
                .frame(minWidth: 340, idealWidth: 380)
            previewPane
                .frame(minWidth: 540, idealWidth: 720)
        }
        .frame(minWidth: 1040, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Library pane (merged: installed widgets + library catalog)

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: title + Install Your Own button
            HStack {
                Text("Library")
                    .font(.headline)
                Spacer()
                Button("Install Your Own…") { model.chooseFilesToImport() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search widgets", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button {
                        model.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // Category filter pills
            categoryFilter

            // Content: installed widgets + library catalog (always in a ScrollView)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Installed widgets section
                    if !model.installed.isEmpty {
                        installedSection
                    }
                    // Library catalog — flat list, filtered by category chip + search
                    libraryList

                    // Recently installed toggle (kept separate from the main list so
                    // categories stay visible beside it, rather than disappearing).
                    if !model.installed.isEmpty && model.showRecentFirst {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "clock.badge.checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                Text("Recently installed")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button("Show all") {
                                    model.showRecentFirst = false
                                }
                                .font(.caption2)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.tint)
                            }
                            .padding(.bottom, 4)
                            ForEach(model.recentlyInstalledPresets) { preset in
                                libraryWidgetRow(preset)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            Divider()
            // Footer: status + drop indicator
            HStack {
                Text(model.status.isEmpty ? "\(model.catalog.presets.count) widgets bundled" : model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.isDropTargeted {
                    Label("Drop to install", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("Your widgets")
                    .font(.subheadline.weight(.semibold))
                Text("(\(model.installed.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 8)

            ForEach(model.installed) { widget in
                installedWidgetRow(widget)
                Divider().padding(.leading, 12)
            }
        }
    }

    private func installedWidgetRow(_ widget: WidgetLibraryModel.Installed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { widget.visible },
                    set: { model.setVisible($0, for: widget.id) }
                ))
                .labelsHidden()
                Text(widget.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Button {
                    if widget.visible {
                        model.confirmRemove(widget)
                    } else {
                        model.confirmDisable(widget)
                    }
                } label: {
                    Image(systemName: widget.visible ? "trash" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .help(widget.visible ? "Remove \(widget.title)" : "Enable \(widget.title)")
            }
            HStack(spacing: 12) {
                Toggle("Behind apps", isOn: Binding(
                    get: { widget.inBackground },
                    set: { model.setInBackground($0, for: widget.id) }
                ))
                .toggleStyle(.checkbox)
                Toggle("All screens", isOn: Binding(
                    get: { widget.onAllScreens },
                    set: { model.setOnAllScreens($0, for: widget.id) }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                Button("Preview") {
                    if let preset = model.catalog.presets.first(where: { $0.id == widget.id }) {
                        model.select(preset)
                    }
                }
                .font(.caption2)
                .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Flat list of library presets (no section headers — filter chips handle categories).
    private var libraryList: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if model.filteredPresets.isEmpty {
                VStack(spacing: 6) {
                    if !model.search.isEmpty || model.selectedCategory != nil {
                        Text("No widgets match")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No bundled widgets")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(model.filteredPresets) { preset in
                    libraryWidgetRow(preset)
                }
            }
        }
    }

    private func libraryWidgetRow(_ preset: Preset) -> some View {
        let installed = model.isInstalled(preset)
        let selected = model.selectedPreset?.id == preset.id
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title)
                    .font(.callout.weight(.medium))
                Text(preset.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if preset.source != "Wijeti" {
                    Text(preset.source)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if installed {
                HStack(spacing: 6) {
                    Button("Installed") { }
                        .disabled(true)
                        .controlSize(.small)
                        .foregroundStyle(.green)
                    Button {
                        model.confirmRemoveInstalled(preset)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Remove \(preset.title)")
                }
            } else {
                Button("Add") {
                    model.confirmInstall(preset)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(preset) }
        .help("Preview \(preset.title)")
    }

    // MARK: - Category filter

    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                categoryChip(nil, label: "All")
                ForEach(model.categories, id: \.self) { category in
                    categoryChip(category, label: category)
                }
                if !model.installed.isEmpty {
                    Divider().frame(height: 18)
                    categoryChip(model.showRecentFirst ? "Recent" : nil, label: "Recent")
                        .opacity(model.categories.isEmpty ? 0.5 : 1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private func categoryChip(_ category: String?, label: String) -> some View {
        let selected: Bool
        if label == "Recent" {
            selected = model.showRecentFirst
        } else {
            selected = model.selectedCategory == category
        }
        return Button {
            if label == "Recent" {
                model.showRecentFirst.toggle()
            } else {
                model.selectedCategory = category
            }
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preview pane (wide)

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                if let preset = model.selectedPreset {
                    Text(preset.category)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Preset info
            if let preset = model.selectedPreset {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.title)
                        .font(.title3.weight(.semibold))
                    Text(preset.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if preset.source != "Wijeti" {
                        Text("Source: \(preset.source)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    HStack {
                        if model.isInstalled(preset) {
                            HStack(spacing: 8) {
                                Text("Installed")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green.opacity(0.15)))
                                Button("Remove") {
                                    model.confirmRemoveInstalled(preset)
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                        } else {
                            Button("Install") {
                                model.doInstall(preset)
                            }
                            .controlSize(.small)
                        }
                        Spacer()
                        Button("Cancel") {
                            model.selectedPreset = nil
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.escape)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            } else {
                // No selection: show hint
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text("Select a widget to preview")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("Pick one from the Library, or drop a .zip / folder here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    Spacer()
                }
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.17, blue: 0.22), Color(red: 0.07, green: 0.07, blue: 0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
            }

            // Live preview web view
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.17, blue: 0.22), Color(red: 0.07, green: 0.07, blue: 0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                if model.selectedPreset == nil {
                    // empty state already shown above
                } else if model.previewReady {
                    PreviewWebView(controller: model.previewController.webViewController)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text(model.previewStatus.isEmpty ? "Starting preview…" : model.previewStatus)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Footer: status + live preview label + popup button
            HStack {
                Text(model.previewStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.selectedPreset != nil {
                    Text("live preview")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()
        }
        .alert(isPresented: $model.showPopup) {
            Alert(
                title: Text(model.popupTitle),
                message: Text(model.popupMessage),
                primaryButton: .default(Text(model.popupActionLabel), action: {
                    model.popupAction?()
                }),
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        guard !providers.isEmpty else { return false }
        group.notify(queue: .main) { model.importDropped(urls) }
        return true
    }
}

/// Mounts the preview controller's web view into SwiftUI. The controller owns the view
/// (it must survive window close/reopen), so `make`/`update` are no-ops beyond mounting.
private struct PreviewWebView: NSViewRepresentable {
    let controller: WidgetWebViewController

    func makeNSView(context: Context) -> WKWebView { controller.webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
