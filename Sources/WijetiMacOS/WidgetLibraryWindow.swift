import AppKit
import SwiftUI
import WebKit
import WijetiCore

/// The onboarding surface: a browsable library of bundled widgets, drag-and-drop or
/// a file picker to bring in your own, and toggles for everything already installed.
///
/// Nothing here needs Finder or a known path — the whole point is that a user can go
/// from "I just installed Wijeti" to "widgets on my desktop" without leaving the app.
public final class WidgetLibraryWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: WidgetLibraryModel

    @MainActor
    public init(model: WidgetLibraryModel) {
        self.model = model
        super.init()
    }

    @MainActor
    public func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: WidgetLibraryView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Wijeti Widget Library"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1140, height: 640))
            window.minSize = NSSize(width: 1040, height: 560)
            window.delegate = self
            self.window = window
        }
        model.reload()
        model.autoSelectIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.resumePreview()
    }

    /// Stops the private preview server (and its node process) when the window closes.
    public func windowWillClose(_ notification: Notification) {
        // Keep the window alive so reopening is instant; just give focus back to nothing.
        // AppKit calls this on the main thread; hop explicitly for the actor check.
        MainActor.assumeIsolated { model.stopPreview() }
        window?.orderOut(nil)
    }

    /// App-wide teardown: the preview server is an extra node process.
    @MainActor
    public func shutdown() {
        model.stopPreview()
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
        installed = host.widgetIDs.map { id in
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
            catalog.presets.map(\.id).filter { folderExists($0) }
        )
    }

    // MARK: - Library

    public var categories: [String] {
        var seen = Set<String>()
        return groups.map { group in
            seen.insert(group.category)
            return group.category
        }
    }

    /// Library rows after the category filter and the search box.
    public var groups: [PresetCatalog.Group] {
        let filtered = catalog.groups.compactMap { group -> PresetCatalog.Group? in
            if let selectedCategory, group.category != selectedCategory { return nil }
            guard !search.isEmpty else { return group }
            let needle = search.lowercased()
            let matching = group.presets.filter {
                $0.title.lowercased().contains(needle)
                    || $0.description.lowercased().contains(needle)
                    || $0.id.lowercased().contains(needle)
            }
            return matching.isEmpty ? nil : PresetCatalog.Group(
                category: group.category, presets: matching
            )
        }
        return filtered
    }

    public func isInstalled(_ preset: Preset) -> Bool { installedPresetIDs.contains(preset.id) }

    /// Copies a bundled preset into the widget directory and reveals it.
    public func install(_ preset: Preset) {
        let source = presetsDirectory.appendingPathComponent(preset.id)
        guard folderExists(preset.id) else {
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
            }
            for failure in result.failures {
                status = "\(preset.title): \(failure.reason)"
            }
            reload()
        } catch {
            status = "Could not install \(preset.title): \(error.localizedDescription)"
        }
    }

    /// Installs several presets at once — the "Add the essentials" path.
    public func install(_ presets: [Preset]) {
        var installed = 0
        var failed: [String] = []
        for preset in presets where !folderExists(preset.id) {
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

    /// Installs whatever the user dropped onto the window.
    public func importDropped(_ urls: [URL]) {
        let usable = urls.filter { importer.canImport($0) }
        guard !usable.isEmpty else {
            status = "Drop a widget folder, or a .jsx / .coffee / .js file."
            return
        }
        do {
            let result = try importer.importWidgets(at: usable)
            var parts: [String] = []
            if !result.installed.isEmpty {
                parts.append("Installed \(result.installed.count)")
                for id in result.installed { host.updateSettings(id) { $0.hidden = false } }
            }
            if !result.skipped.isEmpty { parts.append("already had \(result.skipped.joined(separator: ", "))") }
            if !result.failures.isEmpty {
                parts.append("skipped \(result.failures.first?.reason ?? "some files")")
            }
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

    public func refreshAll() {
        host.refreshWidgets()
        status = "Refreshed."
    }

    // MARK: - Helpers

    private func folderExists(_ id: String) -> Bool {
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
    @State private var isDropTargeted = false

    var body: some View {
        HSplitView {
            installedList
                .frame(minWidth: 250, idealWidth: 280)
            libraryList
                .frame(minWidth: 360, idealWidth: 380)
            previewPane
                .frame(minWidth: 340, idealWidth: 380)
        }
        .frame(minWidth: 1040, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // Installed widgets
    private var installedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your widgets")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if model.installed.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No widgets yet")
                        .font(.callout.weight(.medium))
                    Text("Pick one from the library,\nor drop a widget folder here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.installed) { widget in
                        VStack(alignment: .leading, spacing: 6) {
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
                                    model.remove(widget)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(widget.title)")
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
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Button("Add Widgets…") { model.chooseFilesToImport() }
                Spacer()
                Button("Refresh") { model.refreshAll() }
            }
            .padding(12)
        }
    }

    // Library
    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Library")
                        .font(.headline)
                    Spacer()
                    Button("Install Your Own…") { model.chooseFilesToImport() }
                }
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            categoryFilter

            if model.groups.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing matches “\(model.search)”")
                        .foregroundStyle(.secondary)
                    Text("You can still add your own widget with Install Your Own…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.category.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(group.presets) { preset in
                                    presetRow(preset)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }

            Divider()
            HStack {
                Text(model.status.isEmpty ? "\(model.catalog.presets.count) widgets bundled" : model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if isDropTargeted {
                    Label("Drop to install", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                categoryChip(nil, label: "All")
                ForEach(model.categories, id: \.self) { category in
                    categoryChip(category, label: category)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func categoryChip(_ category: String?, label: String) -> some View {
        let selected = model.selectedCategory == category
        return Button {
            model.selectedCategory = category
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

    private func presetRow(_ preset: Preset) -> some View {
        let installed = model.isInstalled(preset)
        let selected = model.selectedPreset?.id == preset.id
        return HStack(alignment: .top, spacing: 12) {
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
            Button(installed ? "Installed" : "Add") {
                if !installed { model.install(preset) }
            }
            .disabled(installed)
            .controlSize(.small)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(preset) }
        .help("Preview \(preset.title)")
    }

    // Preview pane
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
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
                if let preset = model.selectedPreset {
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
                        Button(model.isInstalled(preset) ? "Installed" : "Install") {
                            model.install(preset)
                        }
                        .disabled(model.isInstalled(preset))
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ZStack {
                // A wallpaper-ish backdrop so light-on-dark widgets read the way they
                // will on the desktop.
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.17, blue: 0.22), Color(red: 0.07, green: 0.07, blue: 0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                if model.selectedPreset == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "cursor.arrow.rays")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Pick a widget to see it live")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white.opacity(0.8))
                        Text("Nothing is installed until you hit Install.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
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

            HStack {
                Text(model.previewStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(model.selectedPreset == nil ? "" : "live preview")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()
        }
    }

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
