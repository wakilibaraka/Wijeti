import AppKit
import SwiftUI
import WijetiCore

/// Backing store for the preferences window. Every toggle sends a settings change through
/// `HostApp`, i.e. over the widget server's message bus, so the change is applied and
/// persisted by the server and the widgets re-render immediately.
public final class PreferencesModel: ObservableObject {
    public struct WidgetRow: Identifiable {
        public let id: String
        public var hidden: Bool
    }

    @Published public var rows: [WidgetRow] = []
    @Published public var widgetDirectory: String = ""
    @Published public var loginShell: Bool = false
    @Published public var launchAtLogin: Bool = LoginItem.isEnabled
    @Published public var status: String = ""

    public enum Tab: String, CaseIterable, Identifiable {
        case general, widgets, permissions, advanced
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .general: return "General"
            case .widgets: return "Widgets"
            case .permissions: return "Permissions"
            case .advanced: return "Advanced"
            }
        }
        public var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .widgets: return "square.grid.2x2"
            case .permissions: return "hand.raised"
            case .advanced: return "slider.horizontal.3"
            }
        }
        /// One line explaining what the pane is for. Also what the sidebar's search matches,
        /// so searching "login" or "engine" finds the pane without knowing its name.
        public var summary: String {
            switch self {
            case .general: return "Choose how Wijeti starts and keep widgets up to date."
            case .widgets: return "See what is installed, then manage it in the Widget Library."
            case .permissions: return "Manage access granted to widgets on this Mac."
            case .advanced: return "Configure the widget engine and developer options."
            }
        }
        /// Extra words a query can match, beyond the title and summary.
        var searchTerms: [String] {
            switch self {
            case .general: return ["updates", "version", "check now", "launch at login", "startup", "welcome tour", "onboarding"]
            case .widgets: return ["installed", "library", "install", "show", "hide", "remove", "desktop"]
            case .permissions: return ["privacy", "access", "location", "weather", "data source", "units", "temperature"]
            case .advanced: return ["server", "engine", "restart", "folder", "directory", "login shell", "developer", "inspect", "web inspector"]
            }
        }

        /// Whether the sidebar query matches this pane.
        func matches(_ query: String) -> Bool {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { return true }
            let haystack = ([title, summary] + searchTerms).joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }

    @Published public var selectedTab: Tab = .general
    /// The Settings sidebar's search query. Filters the pane list only — it never touches the
    /// widget catalog, which is searched from the Library's toolbar.
    @Published public var searchText = ""

    /// Panes matching the sidebar query, in their declared order.
    public var filteredTabs: [Tab] {
        Tab.allCases.filter { $0.matches(searchText) }
    }

    /// Keeps the selection inside the filtered list, so narrowing the search can never leave
    /// the detail pane showing a pane the sidebar no longer lists.
    public func selectFirstVisibleTab() {
        let visible = filteredTabs
        guard !visible.isEmpty, !visible.contains(selectedTab) else { return }
        selectedTab = visible[0]
    }

    public var installedCount: Int { rows.count }
    public var visibleCount: Int { rows.filter { !$0.hidden }.count }
    @Published public var developerMode: Bool = DeveloperMode.isEnabled
    @Published public var serverStatus: String = ""
    @Published public var serverHealthy: Bool = false

    private let host: HostApp

    public init(host: HostApp) {
        self.host = host
        self.loginShell = host.loginShell
        self.widgetDirectory = host.widgetDirectoryURL.path
        reload()
    }

    public func reload() {
        rows = host.widgetIDs.map { id in
            WidgetRow(id: id, hidden: host.settings(for: id).hidden)
        }
        widgetDirectory = host.widgetDirectoryURL.path
        loginShell = host.loginShell
        launchAtLogin = LoginItem.isEnabled
        developerMode = DeveloperMode.isEnabled
        if let port = host.port {
            serverStatus = "Running on port \(port)"
            serverHealthy = true
        } else {
            serverHealthy = false
            serverStatus = host.supervisor.gaveUp
                ? "Stopped — it kept failing to start. Try Restart Server."
                : (host.supervisor.isRunning || host.supervisor.restartScheduled ? "Starting…" : "Not running")
        }
    }

    public func setDeveloperMode(_ enabled: Bool) {
        developerMode = enabled
        UserDefaults.standard.set(enabled, forKey: DeveloperMode.defaultsKey)
        host.coordinator.setInspectable(enabled)
    }

    public func refreshAll() { host.refreshWidgets() }
    public func reloadWidgets() { host.reloadWidgets() }
    public func installPresets() {
        host.installPresets()
        reload()
    }
    public func revealWidgetDirectory() { host.revealWidgetDirectory() }
    public func restartServer() { host.restartServer() }

    public func chooseWidgetDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = host.widgetDirectoryURL
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // The choice used to be discarded with a note telling the user to relaunch by hand,
        // which meant picking a folder did nothing at all. Persist it and restart the server.
        host.setWidgetDirectory(chosen)
        reload()
    }

    public func setLoginShell(_ enabled: Bool) {
        loginShell = enabled
        host.setLoginShell(enabled)
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = LoginItem.setEnabled(enabled)
        if enabled && !launchAtLogin {
            status = "Approve Wijeti in System Settings → General → Login Items."
        }
    }
}

struct WidgetSettingsView: View {
    @ObservedObject var model: PreferencesModel
    @ObservedObject var probe: PermissionProbe
    @ObservedObject var sources: DataSourceSettings
    var onOpenLibrary: () -> Void
    var onShowOnboarding: () -> Void

    var body: some View {
        // `HSplitView`, not `NavigationSplitView`, for a window that has to work at any size:
        // SwiftUI's navigation-split view takes its *content's* ideal height (a pane's scroll
        // view reports its whole content height), so a pane taller than the window made the
        // split view taller than the window too, and the surplus was centred — pushing the pane
        // heading and the sidebar search field out of sight above the window. A split view fills
        // whichever box it is given.
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
            paneColumn
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onOpenLibrary) {
                    Label("Widget Library", systemImage: "square.grid.2x2")
                }
                .help("Browse, preview, and install widgets")
            }
        }
    }

    /// The selected pane: heading, then the pane's own content, then any status line.
    private var paneColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppPaneHeading(title: model.selectedTab.title, subtitle: model.selectedTab.summary)
                .padding(.horizontal, AppMetrics.windowGutter)
                .padding(.top, AppMetrics.paneGutter + 4)
                .padding(.bottom, AppMetrics.sectionSpacing)

            Divider()

            // A definite box for the pane: its scroll view must never be able to report its
            // content height upwards as an ideal size.
            GeometryReader { proxy in
                pageContent
                    .frame(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1))
            }

            if !model.status.isEmpty {
                Divider()
                Label(model.status, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, AppMetrics.windowGutter)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(AppColor.windowSurface)
    }

    /// The Settings sidebar: pane search pinned at the top, then the pane list. Search sits
    /// above the list because it filters the navigation itself; searching *widgets* is the
    /// Library's job and stays in that window's toolbar.
    private var sidebar: some View {
        VStack(spacing: 0) {
            // A definite height: a hosted `NSSearchField` reports no useful height of its own,
            // and leaving it to be measured made the whole split view's ideal height larger
            // than the window, which pushed the top of both columns above the visible area.
            SidebarSearchField(text: $model.searchText, placeholder: "Search settings")
                .frame(height: 24)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .accessibilityLabel("Search settings")

            List(selection: $model.selectedTab) {
                if model.filteredTabs.isEmpty {
                    Text(model.searchText.isEmpty ? "Nothing to show" : "No settings match “\(model.searchText)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    Section("Wijeti") {
                        ForEach(model.filteredTabs) { tab in
                            Label {
                                HStack {
                                    Text(tab.title)
                                    Spacer(minLength: 6)
                                    if tab == .widgets, model.installedCount > 0 {
                                        Text("\(model.installedCount)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel("\(model.installedCount) installed")
                                    }
                                }
                            } icon: {
                                Image(systemName: tab.symbol)
                            }
                            .tag(tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(VisualEffectView(material: .sidebar, blendingMode: .withinWindow))
        .onChange(of: model.searchText) { _, _ in model.selectFirstVisibleTab() }
    }

    private var pageContent: some View {
        Group {
            switch model.selectedTab {
            case .general: generalTab
            case .widgets: widgetsTab
            case .permissions:
                PermissionsView(probe: probe, sources: sources)
            case .advanced: advancedTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Widgets tab

    /// A summary, not a second manager. The Library is the one place widgets are installed,
    /// shown, hidden and removed; repeating its per-widget switches here made the same toggle
    /// appear in two windows with no way to tell which one was authoritative.
    private var widgetsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionSpacing) {
                insetGroupedSection(
                    badge: "square.grid.2x2",
                    tone: .accent,
                    title: "Installed widgets",
                    subtitle: installedSummary,
                    footer: "The Widget Library shows every widget, its live preview and its switches — and is where widgets are added, hidden and removed."
                ) {
                    HStack(spacing: 10) {
                        Button("Open Widget Library…", action: onOpenLibrary)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut("i", modifiers: .command)
                            .help("Browse, preview, install and manage widgets")
                        Button("Refresh All") { model.refreshAll() }
                            .buttonStyle(.bordered)
                            .disabled(model.rows.isEmpty)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, AppMetrics.windowGutter)
            .padding(.top, AppMetrics.sectionSpacing)
        }
    }

    private var installedSummary: String {
        guard !model.rows.isEmpty else { return "Nothing installed yet." }
        let total = model.visibleCount
        return "\(model.rows.count) installed · \(total) shown on the desktop"
    }

    // MARK: - General tab (inset-grouped sections)

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionSpacing) {
                insetGroupedSection(
                    badge: "person.badge.key",
                    tone: .accent,
                    title: "Launch at login",
                    subtitle: "Start Wijeti when you log in.",
                    footer: model.status.isEmpty ? "Wijeti lives in the menu bar and never appears in the Dock." : model.status
                ) {
                    Toggle("Start Wijeti at login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .padding(.vertical, 4)
                }

                UpdatesSection()

                insetGroupedSection(
                    badge: "square.grid.2x2",
                    tone: .accent,
                    title: "Widgets",
                    subtitle: "Browse, install and manage widgets.",
                    footer: "Shortcuts: ⌘L opens the library, ⌘, opens Settings."
                ) {
                    HStack(spacing: 10) {
                        Button("Open Widget Library…", action: onOpenLibrary)
                            .buttonStyle(.borderedProminent)
                        Button("Refresh All") { model.refreshAll() }
                            .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }

                insetGroupedSection(
                    badge: "sparkles",
                    tone: .neutral,
                    title: "Welcome tour",
                    subtitle: "See the one-screen introduction again.",
                    footer: "The tour is optional and never blocks the app: finishing it opens the Widget Library."
                ) {
                    Button("Show Welcome Tour") { onShowOnboarding() }
                        .buttonStyle(.bordered)
                        .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, AppMetrics.windowGutter)
            .padding(.top, AppMetrics.sectionSpacing)
        }
    }

    // MARK: - Advanced tab

    private var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionSpacing) {
                insetGroupedSection(
                    badge: "server.rack",
                    tone: model.serverHealthy ? .positive : .negative,
                    title: "Widget engine",
                    subtitle: model.serverStatus,
                    footer: "The bundled Node server that runs your widgets. It restarts itself if it crashes."
                ) {
                    HStack(spacing: 10) {
                        Button("Restart Server") { model.restartServer() }
                            .buttonStyle(.bordered)
                        Button("Reload Widgets") { model.reloadWidgets() }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }

                insetGroupedSection(
                    badge: "folder",
                    tone: .neutral,
                    title: "Widgets folder",
                    subtitle: model.widgetDirectory,
                    footer: "Changing the folder restarts the server. Widgets in the old folder are left where they are."
                ) {
                    HStack(spacing: 10) {
                        Button("Choose…") { model.chooseWidgetDirectory() }
                            .buttonStyle(.bordered)
                        Button("Reveal in Finder") { model.revealWidgetDirectory() }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }

                insetGroupedSection(
                    badge: "keyboard.badge.ellipsis",
                    tone: .neutral,
                    title: "Login shell",
                    subtitle: "Run widget commands through your shell profile.",
                    footer: "Some widgets need your PATH and aliases. Turning this on restarts the server."
                ) {
                    Toggle("Run commands through a login shell", isOn: Binding(
                        get: { model.loginShell },
                        set: { model.setLoginShell($0) }
                    ))
                    .padding(.vertical, 4)
                }

                insetGroupedSection(
                    badge: "hammer",
                    tone: .neutral,
                    title: "Developer mode",
                    subtitle: "Inspect widgets with Safari’s Web Inspector.",
                    footer: "Enable Safari → Settings → Advanced → Show features for web developers, then choose Develop → this Mac."
                ) {
                    Toggle("Make widgets inspectable", isOn: Binding(
                        get: { model.developerMode },
                        set: { model.setDeveloperMode($0) }
                    ))
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, AppMetrics.windowGutter)
            .padding(.top, AppMetrics.sectionSpacing)
        }
    }
}

// MARK: - Updates

/// Automatic-update controls: the current version, a manual check, and the background-check switch.
private struct UpdatesSection: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        insetGroupedSection(
            badge: "arrow.down.circle",
            tone: .positive,
            title: "Updates",
            subtitle: updates.versionDescription,
            footer: updates.isAvailable
                ? "Wijeti checks for new versions in the background and asks before installing."
                : "Updates are only available in the packaged app."
        ) {
            HStack(spacing: 14) {
                Toggle("Check automatically", isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.automaticallyChecks = $0 }
                ))
                .disabled(!updates.isAvailable)
                Spacer()
                Button("Check Now") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - PreferencesView (compatibility alias)

/// Compatibility type used by code that still references `PreferencesView`.
typealias PreferencesView = WidgetSettingsView

enum WidgetsFooterNote {
    static let text = "Widgets update on their own schedule."
}

// MARK: - Inset-grouped section view

/// One grouped section: a leading badge and heading, a divider, the caller's rows, and an
/// optional footer. Built on the shared design tokens so every Settings pane (and the Library's
/// own cards) share one surface, radius and border.
private struct InsetGroupedSection<Content: View>: View {
    let badge: String
    let tone: AppTone
    let title: String
    let subtitle: String
    let footer: String?
    let content: Content

    init(
        badge: String,
        tone: AppTone = .accent,
        title: String,
        subtitle: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.badge = badge
        self.tone = tone
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tone.fill)
                    Image(systemName: badge)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tone.color)
                }
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppMetrics.cardPadding)
            .padding(.top, AppMetrics.cardPadding - 2)
            .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, AppMetrics.cardPadding)

            content
                .padding(.horizontal, AppMetrics.cardPadding)
                .padding(.top, 4)

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppMetrics.cardPadding)
                    .padding(.bottom, AppMetrics.cardPadding)
            } else {
                Color.clear
                    .padding(.bottom, AppMetrics.cardPadding)
            }
        }
        .appCardSurface()
    }
}

/// Convenience wrapper so callers can write `insetGroupedSection(badge:tone:title:subtitle:footer:content:)`.
private func insetGroupedSection(
    badge: String,
    tone: AppTone = .accent,
    title: String,
    subtitle: String,
    footer: String? = nil,
    @ViewBuilder content: () -> some View
) -> some View {
    InsetGroupedSection(
        badge: badge,
        tone: tone,
        title: title,
        subtitle: subtitle,
        footer: footer,
        content: content
    )
}

// MARK: - Preferences window controller

/// Hosts the SwiftUI preferences window.
public final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: PreferencesModel
    private let probe: PermissionProbe
    private let sources: DataSourceSettings

    @MainActor
    public init(host: HostApp) {
        model = PreferencesModel(host: host)
        probe = PermissionProbe()
        sources = DataSourceSettings()
        super.init()
    }

    @MainActor
    public func show() {
        if window == nil {
            NSLog("opening preferences window")
            let view = WidgetSettingsView(
                model: model,
                probe: probe,
                sources: sources,
                onOpenLibrary: { [weak self] in self?.onOpenLibrary?() },
                onShowOnboarding: { [weak self] in self?.onShowOnboarding?() }
            )
            // The window's own size governs the layout. With a plain `NSHostingController` the
            // hosting view adopted SwiftUI's own height instead (787pt whatever the window
            // size), and a shorter window only pushed the pane heading and the sidebar search
            // field further out of sight above it.
            let hosting = FixedSizedHostingController(rootView: view)
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Settings"
            // Use standard resizable macOS window chrome. Changes apply immediately, so there
            // is intentionally no custom Save/Cancel workflow.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .unified
            window.backgroundColor = .windowBackgroundColor
            // A minimum that still fits a half-screen tile on a 1280-point display; the panes
            // themselves adapt below that rather than requiring a wider window.
            window.minSize = AppMetrics.settingsMinimum
            window.setContentSize(NSSize(width: 860, height: 640))
            pinHostingViewToWindowContent(window)
            window.delegate = self
            self.window = window
        }
        model.reload()
        probe.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        NSLog("preferences window shown with %d widget(s)", model.rows.count)
    }

    /// Re-pins the hosting view after a resize. SwiftUI re-applies the split view's own (content
    /// derived) height on every resize, which drifts the host view out of the window again.
    @MainActor
    public func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        pinHostingViewToWindowContent(window)
    }

    /// Renders the settings window to an image — `--capture-ui` uses this to prove the
    /// chrome rules (modeless, close-only) actually took effect on the real window.
    /// Re-reads server state into the form while the window is on screen, so toggles flipped in
    /// the tray or by AppleScript do not leave it stale.
    @MainActor
    public func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        model.reload()
    }

    @MainActor
    public func select(tab: PreferencesModel.Tab) {
        model.selectedTab = tab
    }

    @MainActor
    public func snapshotWindowImage() -> NSImage? {
        WindowSnapshot.capture(window)
    }

    /// Dev-only helper for `--capture-ui`: resizes the window while it is on screen so the
    /// compact layout can be captured. Nothing in normal use calls this.
    @MainActor
    public func resizeForCapture(width: CGFloat, height: CGFloat) {
        window?.setContentSize(NSSize(width: width, height: height))
    }

    /// Chrome check for `--capture-ui` — logged, not eyeballed.
    @MainActor
    public var chromeSummary: String {
        WindowSnapshot.chromeSummary(of: window)
    }

    /// Layout check for `--capture-ui`: the content view's frame, the window's content layout
    /// rectangle and the hosting view's safe area, so a top-clipped pane can be diagnosed from
    /// the log instead of guessed at.
    @MainActor
    public var layoutSummary: String {
        guard let window else { return "no window" }
        let contentView = window.contentView
        let insets = contentView?.safeAreaInsets ?? .init()
        let children = (contentView?.subviews ?? []).map {
            "\(type(of: $0)) \(NSStringFromRect($0.frame))"
        }.joined(separator: " | ")
        return "frame=\(NSStringFromRect(window.frame)) content=\(contentView.map { NSStringFromRect($0.frame) } ?? "nil") \(type(of: contentView)) "
            + "layout=\(NSStringFromRect(window.contentLayoutRect)) safeTop=\(insets.top) children=[\(children)]"
    }

    /// Set by the app delegate so "Add Widgets" can open the library window.
    public var onOpenLibrary: (() -> Void)?

    /// Set by the app delegate so the General pane can replay the first-run tour.
    public var onShowOnboarding: (() -> Void)?

    /// Opens the widget library from the preferences window.
    public func openLibrary() { onOpenLibrary?() }
}