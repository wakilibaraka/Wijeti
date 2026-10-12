import SwiftUI
import WebKit
import WijetiCore

// MARK: - Library view

/// The Widget Library window's content: navigation on the left, a browsable grid in the middle and
/// an inspector for the selected widget on the right.
///
/// One job per region. The sidebar only chooses *what to browse*; the grid only *discovers and adds*
/// (one button per card); anything that *manages* an installed widget (visibility, layer, screens,
/// remove) lives in the Installed list or the inspector, never on the discovery cards.
struct WidgetLibraryView: View {
    @ObservedObject var model: WidgetLibraryModel

    private enum Source: Hashable {
        case all
        case installed
        case category(String)
    }

    private static let gutter: CGFloat = 16
    private static let radius: CGFloat = 12

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            HStack(spacing: 0) {
                browser
                if model.selectedPreset != nil {
                    Divider()
                    inspector
                        .frame(minWidth: 480, idealWidth: 560, maxWidth: 680)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .animation(.easeInOut(duration: 0.2), value: model.selectedPreset?.id)
        }
        .frame(minWidth: 1100, minHeight: 640)
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay { dropOverlay }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeInOut(duration: 0.15), value: model.isDropTargeted)
        .sheet(item: $model.customizing) { target in
            CustomizeSheet(
                target: target,
                categories: model.assignableCategories,
                onSave: { model.saveCustomization($0) },
                onSkip: { model.skipCustomization() }
            )
        }
        .alert(isPresented: $model.showPopup) {
            Alert(
                title: Text(model.popupTitle),
                message: Text(model.popupMessage),
                primaryButton: .default(Text(model.popupActionLabel), action: { model.popupAction?() }),
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: Sidebar

    private var source: Binding<Source?> {
        Binding(
            get: {
                if model.showRecentFirst { return .installed }
                if let category = model.selectedCategory { return .category(category) }
                return .all
            },
            set: { item in
                switch item {
                case .installed:
                    model.selectedCategory = nil
                    model.showRecentFirst = true
                case .category(let category):
                    model.selectedCategory = category
                    model.showRecentFirst = false
                case .all, .none:
                    model.selectedCategory = nil
                    model.showRecentFirst = false
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: source) {
            Section {
                Label("All Widgets", systemImage: "square.grid.2x2").tag(Source.all)
                Label {
                    HStack {
                        Text("Installed")
                        Spacer()
                        Text("\(model.installed.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .tag(Source.installed)
            }
            Section("Categories") {
                ForEach(model.categories, id: \.self) { category in
                    Label(category, systemImage: Self.symbol(forCategory: category))
                        .tag(Source.category(category))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Keep the first row clear of the traffic lights (the title bar is transparent).
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 28) }
        .background(VisualEffectView(material: .sidebar, blendingMode: .withinWindow))
    }

    private static func symbol(forCategory category: String) -> String {
        switch category {
        case "Calendar": return "calendar"
        case "Clock": return "clock"
        case "Finance": return "chart.line.uptrend.xyaxis"
        case "Fun": return "party.popper"
        case "Lyrics": return "music.mic"
        case "Music": return "music.note"
        case "Productivity": return "checklist"
        case "Quotes": return "quote.bubble"
        case "System": return "gauge.medium"
        case "Weather": return "cloud.sun"
        default: return "square.grid.2x2"
        }
    }

    // MARK: Browser (header + grid / installed list)

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.showRecentFirst {
                installedList
            } else {
                grid
            }
        }
        .frame(minWidth: 380, maxWidth: .infinity)
    }

    private var title: String {
        if model.showRecentFirst { return "Installed" }
        return model.selectedCategory ?? "All Widgets"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.title2.weight(.semibold))
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.search)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))

            Button {
                model.chooseFilesToImport()
            } label: {
                Label("Add Widget", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Add your own widgets: .zip, folders, .jsx, .js, .coffee or .html files")

            Menu {
                Button("Show All Widgets") { model.enableAllVisibleNow() }
                    .disabled(model.installed.isEmpty)
                Button("Hide All Widgets") { model.disableAllNow() }
                    .disabled(model.installed.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            if model.filteredPresets.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: Self.gutter) {
                    LazyVGrid(columns: columns, spacing: Self.gutter) {
                        ForEach(model.filteredPresets) { preset in
                            card(preset)
                        }
                    }
                    if !model.filteredCustomWidgets.isEmpty {
                        Text("Your widgets")
                            .font(.headline)
                            .padding(.top, 4)
                        LazyVGrid(columns: columns, spacing: Self.gutter) {
                            ForEach(model.filteredCustomWidgets) { widget in
                                customCard(widget)
                            }
                        }
                    }
                }
                .padding(Self.gutter)
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: Self.gutter)]
    }

    private func customCard(_ widget: WidgetLibraryModel.Installed) -> some View {
        let selected = model.selectedCustomFolder != nil && model.selectedCustomFolder == widget.folder
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: Self.symbol(forCategory: widget.category ?? "Other"))
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14)))
                Spacer()
                Label(widget.visible ? "On desktop" : "Hidden", systemImage: widget.visible ? "checkmark.circle.fill" : "eye.slash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(widget.visible ? Color.green : Color.secondary)
            }
            Text(widget.title).font(.headline).lineLimit(1)
            Text(widget.category ?? "Uncategorised")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Self.radius).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Self.radius))
        .onTapGesture { selectCustom(widget) }
        .contextMenu { installedMenu(widget) }
    }

    private func selectCustom(_ widget: WidgetLibraryModel.Installed) {
        model.selectedPreset = nil
        model.selectedCustomFolder = widget.folder
    }

    /// Shared right-click / ⋯ menu for anything installed.
    @ViewBuilder
    private func installedMenu(_ widget: WidgetLibraryModel.Installed) -> some View {
        Button(widget.visible ? "Hide from Desktop" : "Show on Desktop") {
            model.setVisible(!widget.visible, for: widget.id)
        }
        Toggle("Behind Other Apps", isOn: Binding(
            get: { widget.inBackground }, set: { model.setInBackground($0, for: widget.id) }
        ))
        Toggle("On Every Screen", isOn: Binding(
            get: { widget.onAllScreens }, set: { model.setOnAllScreens($0, for: widget.id) }
        ))
        Divider()
        if widget.isCustom {
            Button("Rename or Change Category…") { model.beginCustomize(widget) }
        }
        Button("Reveal in Finder") { model.revealOnDisk(widget) }
        Divider()
        Button("Remove…", role: .destructive) { model.confirmRemove(widget) }
    }

    private func card(_ preset: Preset) -> some View {
        let installed = model.isInstalled(preset)
        let selected = model.selectedPreset?.id == preset.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: Self.symbol(forCategory: preset.category))
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14)))
                Spacer()
                if installed {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Button("Add") { model.doInstall(preset) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
            Text(preset.title)
                .font(.headline)
                .lineLimit(1)
            Text(preset.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Self.radius)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Self.radius))
        .onTapGesture { model.select(preset) }
        .help("Preview \(preset.title)")
        .contextMenu {
            if let widget = model.installedWidget(for: preset) {
                installedMenu(widget)
            } else {
                Button("Add to Desktop") { model.doInstall(preset) }
            }
            Divider()
            Button("Preview") { model.select(preset) }
            Button("Reveal Source") { model.revealSource(for: preset) }
            Button("Edit Source") { model.openSource(for: preset) }
        }
    }

    // MARK: Installed list

    private var installedWidgets: [WidgetLibraryModel.Installed] {
        let needle = model.search.lowercased()
        return model.installed.filter {
            needle.isEmpty || $0.title.lowercased().contains(needle) || $0.id.lowercased().contains(needle)
        }
    }

    private var installedList: some View {
        ScrollView {
            if installedWidgets.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(installedWidgets.enumerated()), id: \.element.id) { index, widget in
                        installedRow(widget)
                        if index < installedWidgets.count - 1 { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Self.radius).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(Color.primary.opacity(0.08)))
                .padding(Self.gutter)
            }
        }
    }

    private func installedRow(_ widget: WidgetLibraryModel.Installed) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(widget.visible ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(widget.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let category = widget.category {
                    Text(category).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            switches(widget)
            Menu {
                installedMenu(widget)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu { installedMenu(widget) }
    }

    /// The three per-widget switches. Shown only where a widget is being *managed*.
    private func switches(_ widget: WidgetLibraryModel.Installed) -> some View {
        HStack(spacing: 14) {
            Toggle("Visible", isOn: Binding(
                get: { widget.visible },
                set: { model.setVisible($0, for: widget.id) }
            ))
            Toggle("Behind apps", isOn: Binding(
                get: { widget.inBackground },
                set: { model.setInBackground($0, for: widget.id) }
            ))
            Toggle("All screens", isOn: Binding(
                get: { widget.onAllScreens },
                set: { model.setOnAllScreens($0, for: widget.id) }
            ))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .fixedSize()
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.showRecentFirst ? "tray" : (model.search.isEmpty ? "square.grid.2x2" : "magnifyingglass"))
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            if model.showRecentFirst && model.search.isEmpty {
                Text("No widgets installed yet").font(.headline)
                Text("Add one from All Widgets, or add your own.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Add Widget") { model.chooseFilesToImport() }
                    .buttonStyle(.borderedProminent)
            } else if !model.search.isEmpty {
                Text("No widgets match “\(model.search)”").font(.headline)
                Button("Clear Search") { model.search = "" }
            } else if let problem = model.catalogProblem {
                Text("The widget library didn’t load").font(.headline)
                Text(problem).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(model.libraryDirectoryDisplayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Button("Reveal Library Folder") { model.revealLibraryDirectory() }
            } else {
                Text("Nothing here yet").font(.headline)
                Text("Drop a folder or .zip here, or press Add Widget.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let folder = model.selectedCustomFolder,
               let widget = model.installed.first(where: { $0.folder == folder }) {
                customInspector(widget)
            } else if let preset = model.selectedPreset {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(preset.title).font(.title3.weight(.semibold))
                        Spacer()
                        Button { model.selectedPreset = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.escape, modifiers: [])
                        .help("Close preview")
                    }
                    Text(preset.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        tag(preset.category)
                        if preset.source != "Wijeti" { tag("by \(preset.source)") }
                    }
                }
                .padding(Self.gutter)

                preview
                    .padding(.horizontal, Self.gutter)

                inspectorActions(preset)
                    .padding(Self.gutter)
            }
        }
    }

    @ViewBuilder
    private func customInspector(_ widget: WidgetLibraryModel.Installed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(widget.title).font(.title3.weight(.semibold))
                Spacer()
                Button { model.selectedCustomFolder = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            HStack(spacing: 6) {
                tag(widget.category ?? "Uncategorised")
                tag("Your widget")
            }
        }
        .padding(Self.gutter)

        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack").font(.system(size: 36, weight: .light))
            Text("Imported widgets run on your desktop")
                .font(.headline)
            Text("Use the switches below to show it, place it behind other apps or repeat it on every screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Self.radius).fill(Color.secondary.opacity(0.08)))
        .padding(.horizontal, Self.gutter)

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Visible on desktop", isOn: Binding(
                    get: { widget.visible }, set: { model.setVisible($0, for: widget.id) }
                ))
                Toggle("Behind other apps", isOn: Binding(
                    get: { widget.inBackground }, set: { model.setInBackground($0, for: widget.id) }
                ))
                Toggle("On every screen", isOn: Binding(
                    get: { widget.onAllScreens }, set: { model.setOnAllScreens($0, for: widget.id) }
                ))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            HStack(spacing: 8) {
                Button("Rename or Change Category…") { model.beginCustomize(widget) }
                Button("Reveal") { model.revealOnDisk(widget) }
                Spacer()
                Button("Remove", role: .destructive) { model.confirmRemove(widget) }
                    .foregroundStyle(.red)
            }
            .controlSize(.small)
        }
        .padding(Self.gutter)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
    }

    private var preview: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.17, blue: 0.22), Color(red: 0.07, green: 0.07, blue: 0.1)],
                startPoint: .top, endPoint: .bottom
            )
            if model.previewReady {
                PreviewWebView(controller: model.previewController.webViewController)
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(model.previewStatus.isEmpty ? "Starting preview…" : model.previewStatus)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(minHeight: 360, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(.white.opacity(0.08)))
    }

    @ViewBuilder
    private func inspectorActions(_ preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let widget = model.installedWidget(for: preset) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Visible on desktop", isOn: Binding(
                        get: { widget.visible }, set: { model.setVisible($0, for: widget.id) }
                    ))
                    Toggle("Behind other apps", isOn: Binding(
                        get: { widget.inBackground }, set: { model.setInBackground($0, for: widget.id) }
                    ))
                    Toggle("On every screen", isOn: Binding(
                        get: { widget.onAllScreens }, set: { model.setOnAllScreens($0, for: widget.id) }
                    ))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            } else if model.isInstalled(preset) {
                Text("Installed. Settings appear once the widget server picks it up.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Add to Desktop") { model.doInstall(preset) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            HStack(spacing: 8) {
                Button("Reveal") { model.revealSource(for: preset) }
                Button("Edit Source") { model.openSource(for: preset) }
                Spacer()
                if model.isInstalled(preset) {
                    Button("Remove", role: .destructive) { model.confirmRemoveInstalled(preset) }
                        .foregroundStyle(.red)
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: Drop, toast

    @ViewBuilder
    private var dropOverlay: some View {
        if model.isDropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.12))
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc.fill").font(.system(size: 40))
                    Text("Drop to install").font(.title3.weight(.semibold))
                    Text("Folders, .zip, .jsx and .js files")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(8)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var toast: some View {
        if !model.status.isEmpty {
            Text(model.status)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: model.status)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
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

// MARK: - Rename / classify sheet

/// Names and files an imported widget. Shown after an import and from the right-click menu.
private struct CustomizeSheet: View {
    @State var target: WidgetLibraryModel.CustomizeTarget
    let categories: [String]
    let onSave: (WidgetLibraryModel.CustomizeTarget) -> Void
    let onSkip: () -> Void

    @State private var creatingCategory = false
    @State private var newCategory = ""

    init(
        target: WidgetLibraryModel.CustomizeTarget,
        categories: [String],
        onSave: @escaping (WidgetLibraryModel.CustomizeTarget) -> Void,
        onSkip: @escaping () -> Void
    ) {
        _target = State(initialValue: target)
        self.categories = categories
        self.onSave = onSave
        self.onSkip = onSkip
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Name your widget")
                .font(.title3.weight(.semibold))
            Text("Choose how it appears in the library. The files on disk are not renamed.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Widget name", text: $target.title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Category").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if creatingCategory {
                    HStack {
                        TextField("New category", text: $newCategory)
                            .textFieldStyle(.roundedBorder)
                        Button("Cancel") { creatingCategory = false; newCategory = "" }
                    }
                } else {
                    Picker("Category", selection: $target.category) {
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    Button("New Category…") { creatingCategory = true }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button("Skip") { onSkip() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var result = target
                    if creatingCategory, !newCategory.trimmingCharacters(in: .whitespaces).isEmpty {
                        result.category = newCategory
                    }
                    onSave(result)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(target.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var options: [String] {
        categories.contains(target.category) ? categories : categories + [target.category]
    }
}
