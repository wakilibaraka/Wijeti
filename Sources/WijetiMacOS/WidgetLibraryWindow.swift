import AppKit
import SwiftUI
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
            window.setContentSize(NSSize(width: 760, height: 560))
            window.delegate = self
            self.window = window
        }
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        // Keep the window alive so reopening is instant; just give focus back to nothing.
        window?.orderOut(nil)
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

    private let host: HostApp
    private let importer: WidgetImporter
    private let presetsDirectory: URL

    public init(host: HostApp, presetsDirectory: URL) {
        self.host = host
        self.presetsDirectory = presetsDirectory
        self.importer = WidgetImporter(widgetDirectory: host.widgetDirectoryURL)
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
                .frame(minWidth: 380)
        }
        .frame(minWidth: 720, minHeight: 520)
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
