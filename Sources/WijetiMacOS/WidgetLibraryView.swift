import SwiftUI
import WebKit
import WijetiCore

// MARK: - Library view

/// The Widget Library window's content: a native navigation sidebar, searchable widget gallery,
/// and an inspector that stays beside the live preview.
///
/// The sidebar navigates; the gallery previews and installs; the inspector manages installed
/// widgets. System controls handle the title bar, toolbar, selection, and search.
struct WidgetLibraryView: View {
    @ObservedObject var model: WidgetLibraryModel

    private enum Source: Hashable {
        case all
        case installed
        case category(String)
    }

    // Shared metrics: the library uses the same spacing and radii as Settings and onboarding.
    private static let gutter = AppMetrics.paneGutter
    private static let radius = AppMetrics.cardRadius
    private static let cardRadius = AppMetrics.smallRadius

    @AppStorage("library.viewMode") private var viewMode = "grid"
    @AppStorage("library.sidebarCollapsed") private var sidebarCollapsed = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The window's content width, used to decide whether the gallery and the preview can share
    /// the row or whether one has to take over the content area.
    @State private var contentWidth: CGFloat = 1400
    /// True while the sidebar was folded away by the narrow layout rather than by the user, so
    /// widening the window restores it without overruling a manual choice.
    @State private var autoCollapsedSidebar = false

    private var showsInspector: Bool {
        model.selectMode || model.selectedPreset != nil || model.selectedCustomFolder != nil
    }

    /// A half-screen tile (or any narrow window) cannot hold a category sidebar, the gallery and
    /// the preview at once. Below this width the layout keeps a single content pane.
    private var isCompact: Bool {
        contentWidth > 0 && contentWidth < AppMetrics.librarySideBySideMinimum
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            // The pane layout is driven from a measured box rather than from the column's own
            // proposal: the hosted preview is a real `WKWebView`, and handing it an unbounded
            // height let it size itself to its page content (measured at 1195pt tall inside a
            // 520pt window) and paint over the rest of the window.
            GeometryReader { proxy in
                detailContent(in: proxy.size)
            }
            .background(AppColor.windowSurface)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search widgets")
        .background(widthReader)
        .onChange(of: contentWidth) { _, _ in updateLayoutForWidth() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(columnVisibility == .detailOnly ? "Show categories" : "Hide categories")
                .accessibilityLabel(columnVisibility == .detailOnly ? "Show categories" : "Hide categories")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Widget layout", selection: $viewMode) {
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
                    Label("Import Widget", systemImage: "plus")
                }
                .help("Add your own widgets: .zip, folders, .jsx, .js, .coffee or .html files")

                Menu {
                    if columnVisibility == .detailOnly {
                        Button("All Widgets") { model.selectedCategory = nil; model.showRecentFirst = false }
                        Button("Installed") { model.selectedCategory = nil; model.showRecentFirst = true }
                        Divider()
                        ForEach(model.categories, id: \.self) { category in
                            Button(category) { model.selectedCategory = category; model.showRecentFirst = false }
                        }
                        Divider()
                    }
                    Button("Select All") { selectAll(items) }
                        .keyboardShortcut("a", modifiers: .command)
                    Divider()
                    Button("Show All Widgets") { model.enableAllVisibleNow() }
                        .disabled(model.installed.isEmpty)
                    Button("Hide All Widgets") { model.disableAllNow() }
                        .disabled(model.installed.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .help("More widget actions")
                .accessibilityLabel("More widget actions")
            }
        }
        .onAppear {
            columnVisibility = sidebarCollapsed ? .detailOnly : .all
            updateLayoutForWidth()
        }
        .onChange(of: columnVisibility) { _, value in
            // Only a change the user made is remembered as their preference.
            guard !autoCollapsedSidebar || value == .all else { return }
            sidebarCollapsed = (value == .detailOnly)
        }
        .frame(minWidth: AppMetrics.libraryMinimum.width, minHeight: AppMetrics.libraryMinimum.height)
        .background(AppColor.windowSurface)
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
        .alert(model.popupTitle, isPresented: $model.showPopup) {
            Button(model.popupActionLabel) { model.popupAction?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.popupMessage)
        }
    }

    // MARK: Adaptation

    /// Reports the content width, so the layout can react to a tiled or resized window.
    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { contentWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in contentWidth = width }
        }
    }

    /// Folds the category sidebar away when there is not enough width for three columns, and
    /// restores it when the window grows again — unless the user had collapsed it themselves.
    private func updateLayoutForWidth() {
        guard contentWidth > 0 else { return }
        if isCompact {
            guard columnVisibility != .detailOnly else { return }
            autoCollapsedSidebar = true
            columnVisibility = .detailOnly
        } else if autoCollapsedSidebar {
            autoCollapsedSidebar = false
            columnVisibility = sidebarCollapsed ? .detailOnly : .all
        }
    }

    /// Gallery and inspector share the row when there is room; otherwise one takes over. Both
    /// branches pin their children to a definite box, so the preview always has a bounded frame.
    @ViewBuilder
    private func detailContent(in size: CGSize) -> some View {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        if isCompact {
            if showsInspector {
                inspector
                    .frame(width: width, height: height)
            } else {
                browser
                    .frame(width: width, height: height)
            }
        } else {
            HStack(spacing: 0) {
                browser
                if showsInspector {
                    Divider()
                    inspector
                        .frame(width: min(max(width * 0.42, 420), 680), height: height)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: width, height: height)
            .animation(.easeInOut(duration: 0.2), value: showsInspector)
        }
    }

    /// Leaves the preview/management pane and returns to the gallery — the compact layout shows
    /// one pane at a time, so there has to be a way back.
    private func closeInspector() {
        model.selectMode = false
        model.selection.clear()
        model.selectedPreset = nil
        model.selectedCustomFolder = nil
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
            Section("Library") {
                Label("All Widgets", systemImage: "square.grid.2x2")
                    .tag(Source.all)
                Label {
                    HStack {
                        Text("Installed")
                        Spacer()
                        Text("\(model.installed.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .tag(Source.installed)
            }
            Section("Browse by category") {
                ForEach(model.categories, id: \.self) { category in
                    Label(category, systemImage: Self.symbol(forCategory: category))
                        .tag(Source.category(category))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(items.count)")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                    .accessibilityLabel("\(items.count) widgets")
            }
            HStack(spacing: 8) {
                if model.showRecentFirst {
                    Label("Your widgets", systemImage: "checkmark.circle")
                } else if let category = model.selectedCategory {
                    Label(category, systemImage: Self.symbol(forCategory: category))
                } else {
                    Label("Explore the library", systemImage: "sparkles")
                }
                Text("·")
                Text(model.search.isEmpty ? "Select a widget to preview it" : "Results update as you type")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            RoundedRectangle(cornerRadius: Self.cardRadius)
                .fill(model.selectMode && chosen ? Color.accentColor : Color.accentColor.opacity(0.12))
            Image(systemName: model.selectMode
                ? (chosen ? "checkmark" : "circle")
                : Self.symbol(forCategory: item.category))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(model.selectMode && chosen ? Color.white : Color.accentColor)
        }
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func statusView(_ item: LibraryItem) -> some View {
        if let widget = item.widget {
            AppStatusBadge(
                text: widget.visible ? "Installed" : "Hidden",
                tone: widget.visible ? .positive : .neutral,
                symbol: widget.visible ? "checkmark.circle.fill" : "eye.slash"
            )
        } else if let preset = item.preset {
            Button {
                model.doInstall(preset)
            } label: {
                Label("Install", systemImage: "arrow.down.to.line")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .help("Install \(preset.title) on your desktop")
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
        // Wide enough that a tiled window gets two comfortable columns rather than three
        // cramped ones whose titles and status badges truncate.
        [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: Self.gutter)]
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
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                handleTap(item, in: items)
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 10) {
                        leadingIcon(item)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(item.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if item.widget != nil { statusView(item) }
                    }
                    Text(item.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                    HStack {
                        if selected {
                            Label(model.selectMode ? "Selected" : "Previewing", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                        } else {
                            Text("Preview widget")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(item.title)")
            .accessibilityHint("Shows a live preview and widget options")

            HStack {
                Text(item.isCustom ? "YOUR WIDGET" : "WIDGET")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if item.widget == nil { statusView(item) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Self.radius)
                .fill(AppColor.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius)
                .strokeBorder(selected ? AppColor.selectedBorder : AppColor.border,
                              lineWidth: selected ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.radius))
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
            .background(RoundedRectangle(cornerRadius: Self.radius).fill(AppColor.surface))
            .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(AppColor.border))
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
            // No inline switches here: the inspector beside the preview is the one place a
            // widget's show/hide, placement and screen settings are changed, so the same
            // widget is not represented by two competing sets of controls.
            statusView(item)
                .fixedSize()
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
                    if isCompact {
                        backToGalleryButton
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(preset.title).font(.title3.weight(.semibold))
                        Spacer()
                        // In the compact layout the back button above already returns to the
                        // gallery, so a second control that does the same thing is left out.
                        if !isCompact {
                            Button { model.selectedPreset = nil } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.escape, modifiers: [])
                            .help("Close preview")
                        }
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

    /// Shown in the narrow layout, where the preview/management pane replaces the gallery.
    private var backToGalleryButton: some View {
        Button { closeInspector() } label: {
            Label("Library", systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .help("Back to the widget gallery")
    }

    @ViewBuilder
    private func customInspector(_ widget: WidgetLibraryModel.Installed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCompact {
                backToGalleryButton
            }
            HStack(alignment: .firstTextBaseline) {
                Text(widget.title).font(.title3.weight(.semibold))
                Spacer()
                if !isCompact {
                    Button { model.selectedCustomFolder = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
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
        AppChip(text: text)
    }

    private var preview: some View {
        ZStack {
            AppColor.recessedSurface
            if model.previewReady {
                PreviewWebView(controller: model.previewController.webViewController)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.previewStatus.isEmpty ? "Preparing preview…" : model.previewStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding(20)
            }
        }
        .frame(minHeight: 280, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(AppColor.border))
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
