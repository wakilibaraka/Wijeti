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

    @AppStorage("library.viewMode") private var viewMode = "grid"
    @AppStorage("library.sidebarCollapsed") private var sidebarCollapsed = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var showsInspector: Bool {
        model.selectMode || model.selectedPreset != nil || model.selectedCustomFolder != nil
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            HStack(spacing: 0) {
                browser
                if showsInspector {
                    Divider()
                    inspector
                        .frame(minWidth: 480, idealWidth: 560, maxWidth: 680)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .animation(.easeInOut(duration: 0.2), value: showsInspector)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { columnVisibility = sidebarCollapsed ? .detailOnly : .all }
        .onChange(of: columnVisibility) { _, value in sidebarCollapsed = (value == .detailOnly) }
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

    // MARK: Items

    /// One thing in the library, whether bundled, imported, installed or not.
    private struct LibraryItem: Identifiable {
        let key: String
        var id: String { key }
        let title: String
        let subtitle: String
        let category: String
        let preset: Preset?
        let widget: WidgetLibraryModel.Installed?
        var isCustom: Bool { preset == nil }
    }

    private var items: [LibraryItem] {
        if model.showRecentFirst {
            let needle = model.search.lowercased()
            return model.installed
                .filter { needle.isEmpty || $0.title.lowercased().contains(needle) }
                .map { widget in
                    let preset = widget.folder.flatMap { model.preset(forKey: $0) }
                    return LibraryItem(
                        key: widget.folder ?? widget.id,
                        title: widget.title,
                        subtitle: preset?.description ?? "Your widget",
                        category: preset?.category ?? widget.category ?? "Other",
                        preset: preset,
                        widget: widget
                    )
                }
        }
        let bundled = model.filteredPresets.map { preset in
            LibraryItem(
                key: preset.id, title: preset.title, subtitle: preset.description,
                category: preset.category, preset: preset, widget: model.installedWidget(for: preset)
            )
        }
        let custom = model.filteredCustomWidgets.map { widget in
            LibraryItem(
                key: widget.folder ?? widget.id, title: widget.title, subtitle: "Your widget",
                category: widget.category ?? "Other", preset: nil, widget: widget
            )
        }
        return bundled + custom
    }

    // MARK: Browser (header + grid / list)

    private var browser: some View {
        let items = self.items
        return VStack(alignment: .leading, spacing: 0) {
            header(items)
            Divider()
            if items.isEmpty {
                ScrollView { emptyState }
            } else if viewMode == "list" {
                listView(items)
            } else {
                gridView(items)
            }
        }
        .frame(minWidth: 380, maxWidth: .infinity)
    }

    private var title: String {
        if model.showRecentFirst { return "Installed" }
        return model.selectedCategory ?? "All Widgets"
    }

    private func header(_ items: [LibraryItem]) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help(columnVisibility == .detailOnly ? "Show categories" : "Hide categories")
            .keyboardShortcut("s", modifiers: [.command, .control])

            Text(title)
                .font(.title2.weight(.semibold))
            if columnVisibility == .detailOnly {
                Menu {
                    Button("All Widgets") { model.selectedCategory = nil; model.showRecentFirst = false }
                    Button("Installed") { model.selectedCategory = nil; model.showRecentFirst = true }
                    Divider()
                    ForEach(model.categories, id: \.self) { category in
                        Button(category) { model.selectedCategory = category; model.showRecentFirst = false }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Browse categories")
            }
            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.search)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 90, maxWidth: 150)
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

            Picker("View", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag("grid")
                Image(systemName: "list.bullet").tag("list")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)
            .help("Switch between grid and list")

            if model.selectMode {
                Button("Done") { model.exitSelectMode() }
                    .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button("Select") {
                    model.selectedPreset = nil
                    model.selectedCustomFolder = nil
                    model.selectMode = true
                }
                .help("Select several widgets to manage them together")
            }

            Button {
                model.chooseFilesToImport()
            } label: {
                Label("Add Widget", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Add your own widgets: .zip, folders, .jsx, .js, .coffee or .html files")

            Menu {
                Button("Select All") { selectAll(items) }
                    .keyboardShortcut("a", modifiers: .command)
                Divider()
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

    private func selectAll(_ items: [LibraryItem]) {
        model.selectedPreset = nil
        model.selectedCustomFolder = nil
        model.selectMode = true
        model.selection.selectAll(items.map(\.key))
    }

    // MARK: Selection and tap handling

    /// Click behaviour shared by cards and rows: ⌘ toggles, ⇧ extends a range, and in select
    /// mode every click toggles. Otherwise a click opens the single-item inspector.
    private func handleTap(_ item: LibraryItem, in items: [LibraryItem]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), model.selectMode || !model.selection.isEmpty {
            model.selectMode = true
            model.selection.extend(to: item.key, in: items.map(\.key))
        } else if flags.contains(.command) || model.selectMode {
            model.selectMode = true
            model.selectedPreset = nil
            model.selectedCustomFolder = nil
            model.selection.toggle(item.key)
        } else if let preset = item.preset {
            model.select(preset)
        } else if let widget = item.widget {
            model.selectedPreset = nil
            model.selectedCustomFolder = widget.folder
        }
    }

    private func isSelected(_ item: LibraryItem) -> Bool {
        if model.selectMode { return model.selection.contains(item.key) }
        if let preset = item.preset { return model.selectedPreset?.id == preset.id }
        return model.selectedCustomFolder != nil && model.selectedCustomFolder == item.widget?.folder
    }

    private func leadingIcon(_ item: LibraryItem) -> some View {
        let chosen = model.selection.contains(item.key)
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(model.selectMode && chosen ? 0.9 : 0.14))
            Image(systemName: model.selectMode
                ? (chosen ? "checkmark" : "circle")
                : Self.symbol(forCategory: item.category))
                .font(.title3)
                .foregroundStyle(model.selectMode && chosen ? Color.white : Color.accentColor)
        }
        .frame(width: 32, height: 32)
    }

    @ViewBuilder
    private func statusView(_ item: LibraryItem) -> some View {
        if let widget = item.widget {
            Label(widget.visible ? "Installed" : "Hidden",
                  systemImage: widget.visible ? "checkmark.circle.fill" : "eye.slash")
                .font(.caption.weight(.medium))
                .foregroundStyle(widget.visible ? Color.green : Color.secondary)
        } else if let preset = item.preset {
            Button("Add") { model.doInstall(preset) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: LibraryItem) -> some View {
        if let widget = item.widget {
            installedMenu(widget)
        } else if let preset = item.preset {
            Button("Add to Desktop") { model.doInstall(preset) }
        }
        if let preset = item.preset {
            Divider()
            Button("Preview") { model.select(preset) }
            Button("Reveal Source") { model.revealSource(for: preset) }
            Button("Edit Source") { model.openSource(for: preset) }
        }
        Divider()
        Button(model.selection.contains(item.key) ? "Deselect" : "Select") {
            model.selectMode = true
            model.selectedPreset = nil
            model.selectedCustomFolder = nil
            model.selection.toggle(item.key)
        }
    }

    // MARK: Grid

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: Self.gutter)]
    }

    private func gridView(_ items: [LibraryItem]) -> some View {
        let bundled = items.filter { !$0.isCustom }
        let custom = items.filter { $0.isCustom }
        return ScrollView {
            VStack(alignment: .leading, spacing: Self.gutter) {
                LazyVGrid(columns: columns, spacing: Self.gutter) {
                    ForEach(bundled) { card($0, in: items) }
                }
                if !custom.isEmpty {
                    Text("Your widgets").font(.headline).padding(.top, 4)
                    LazyVGrid(columns: columns, spacing: Self.gutter) {
                        ForEach(custom) { card($0, in: items) }
                    }
                }
            }
            .padding(Self.gutter)
        }
    }

    private func card(_ item: LibraryItem, in items: [LibraryItem]) -> some View {
        let selected = isSelected(item)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                leadingIcon(item)
                Spacer()
                statusView(item)
            }
            Text(item.title).font(.headline).lineLimit(1)
            Text(item.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Self.radius).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Self.radius))
        .onTapGesture { handleTap(item, in: items) }
        .contextMenu { itemMenu(item) }
    }

    // MARK: List

    private func listView(_ items: [LibraryItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item, in: items)
                    if index < items.count - 1 { Divider().padding(.leading, 58) }
                }
            }
            .background(RoundedRectangle(cornerRadius: Self.radius).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(Color.primary.opacity(0.08)))
            .padding(Self.gutter)
        }
    }

    private func row(_ item: LibraryItem, in items: [LibraryItem]) -> some View {
        HStack(spacing: 12) {
            leadingIcon(item)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.medium).lineLimit(1)
                    tag(item.category)
                }
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let widget = item.widget {
                switches(widget)
            }
            statusView(item)
                .frame(minWidth: 70, alignment: .trailing)
            if let widget = item.widget {
                Menu { installedMenu(widget) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected(item) ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { handleTap(item, in: items) }
        .contextMenu { itemMenu(item) }
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

    /// The three per-widget switches. Shown only where a widget is being *managed*.
    private func switches(_ widget: WidgetLibraryModel.Installed) -> some View {
        HStack(spacing: 14) {
            Toggle("Visible", isOn: Binding(
                get: { widget.visible },
                set: { model.setVisible($0, for: widget.id) }
            ))
            Toggle("Behind", isOn: Binding(
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
            if model.selectMode {
                bulkPanel
            } else if let folder = model.selectedCustomFolder,
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

    // MARK: Bulk panel

    @State private var bulkCategory = ""
    @State private var creatingBulkCategory = false

    private var bulkPanel: some View {
        let count = model.selection.count
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(count == 0 ? "Select widgets" : "\(count) selected")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { model.exitSelectMode() }
                    .controlSize(.small)
            }
            if count == 0 {
                Text("Click widgets to select them. ⌘-click toggles one, ⇧-click selects a range, ⌘A selects everything shown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let notInstalled = model.selectedPresets.filter { !model.isInstalled($0) }.count
                if notInstalled > 0 {
                    Button("Add \(notInstalled) to Desktop") { model.bulkInstall() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                GroupBox("Show") {
                    HStack {
                        Button("Show") { model.bulkSetVisible(true) }
                        Button("Hide") { model.bulkSetVisible(false) }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                GroupBox("Placement") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Behind other apps").frame(width: 150, alignment: .leading)
                            Button("On") { model.bulkSetInBackground(true) }
                            Button("Off") { model.bulkSetInBackground(false) }
                        }
                        HStack {
                            Text("On every screen").frame(width: 150, alignment: .leading)
                            Button("On") { model.bulkSetOnAllScreens(true) }
                            Button("Off") { model.bulkSetOnAllScreens(false) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                GroupBox("Category (imported widgets)") {
                    HStack {
                        if creatingBulkCategory {
                            TextField("New category", text: $bulkCategory)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("Category", selection: $bulkCategory) {
                                Text("Choose…").tag("")
                                ForEach(model.assignableCategories, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        }
                        Button(creatingBulkCategory ? "Pick Existing" : "New…") {
                            creatingBulkCategory.toggle()
                            bulkCategory = ""
                        }
                        Button("Apply") { model.bulkSetCategory(bulkCategory) }
                            .disabled(bulkCategory.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.vertical, 4)
                }
                Spacer(minLength: 0)
                Button("Remove \(model.selectedInstalled.count) Installed…", role: .destructive) {
                    model.confirmBulkRemove()
                }
                .foregroundStyle(.red)
                .disabled(model.selectedInstalled.isEmpty)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
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
