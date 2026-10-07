import AppKit
import ServiceManagement
import SwiftUI
import WijetiCore

/// Backing store for the preferences window. Every toggle sends a settings change through
/// `HostApp`, i.e. over the widget server's message bus, so the change is applied and
/// persisted by the server and the widgets re-render immediately.
public final class PreferencesModel: ObservableObject {
    public struct WidgetRow: Identifiable {
        public let id: String
        public var hidden: Bool
        public var inBackground: Bool
        public var showOnAllScreens: Bool
    }

    @Published public var rows: [WidgetRow] = []
    @Published public var widgetDirectory: String = ""
    @Published public var loginShell: Bool = false
    @Published public var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published public var status: String = ""

    public enum Tab: String, CaseIterable, Identifiable {
        case widgets, general, permissions
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .widgets: return "Widgets"
            case .general: return "General"
            case .permissions: return "Permissions"
            }
        }
    }

    @Published public var selectedTab: Tab = .widgets

    private let host: HostApp

    public init(host: HostApp) {
        self.host = host
        self.loginShell = host.loginShell
        self.widgetDirectory = host.widgetDirectoryURL.path
        reload()
    }

    public func reload() {
        rows = host.widgetIDs.map { id in
            let settings = host.settings(for: id)
            return WidgetRow(
                id: id,
                hidden: settings.hidden,
                inBackground: settings.inBackground,
                showOnAllScreens: settings.showOnAllScreens
            )
        }
        widgetDirectory = host.widgetDirectoryURL.path
    }

    public func setHidden(_ hidden: Bool, for id: String) {
        host.updateSettings(id) { $0.hidden = hidden }
        reload()
    }

    public func setInBackground(_ value: Bool, for id: String) {
        host.updateSettings(id) { $0.inBackground = value }
        reload()
    }

    public func setShowOnAllScreens(_ value: Bool, for id: String) {
        host.updateSettings(id) { $0.showOnAllScreens = value }
        reload()
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
        status = "Restart Wijeti to use \(chosen.lastPathComponent)"
        NSLog("widget directory chosen: %@ (restart required)", chosen.path)
    }

    public func setLoginShell(_ enabled: Bool) {
        loginShell = enabled
        host.setLoginShell(enabled)
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .requiresApproval {
                    try SMAppService.openSystemSettingsLoginItems()
                } else {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            status = "Login item error: \(error.localizedDescription)"
        }
    }
}

struct WidgetSettingsView: View {
    @ObservedObject var model: PreferencesModel
    @ObservedObject var probe: PermissionProbe
    @ObservedObject var sources: DataSourceSettings
    var onOpenLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch model.selectedTab {
                case .widgets: widgetsTab
                case .general: generalTab
                case .permissions:
                    PermissionsView(probe: probe, sources: sources)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(model.status.isEmpty ? WidgetsFooterNote.text : model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Widget Library…", action: onOpenLibrary)
                    .controlSize(.small)
                Button("Close") { NSApp.keyWindow?.performClose(nil) }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 620)
    }

    // MARK: - Header

    private var header: some View {            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                        Text("Wijeti")
                            .font(.title3.bold())
                    }
                    Text("Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $model.selectedTab) {
                    ForEach(PreferencesModel.Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
    }

    // MARK: - Widgets tab (inset-grouped sections)

    private var widgetsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                insetGroupedSection(
                    badge: "square.grid.2x2",
                    badgeColor: .blue,
                    title: "Installed widgets",
                    subtitle: model.rows.isEmpty
                        ? "Nothing installed yet."
                        : "\(model.rows.count) installed",
                    footer: "Open the Widget Library to browse bundled widgets, or drop your own widget folder onto it."
                ) {
                    if model.rows.isEmpty {
                        emptyWidgetsRow
                    } else {
                        ForEach(model.rows) { row in
                            widgetRow(row)
                        }
                    }
                }
                .padding(.bottom, 8)

                insetGroupedSection(
                    badge: "plus.square.on.square",
                    badgeColor: .green,
                    title: "Add widgets",
                    subtitle: "Browse bundled widgets or install your own.",
                    footer: nil
                ) {
                    Button("Open Widget Library…", action: onOpenLibrary)                            .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut("i", modifiers: .command)
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
        }
    }

    private var emptyWidgetsRow: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.dashed.on.square")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Open the Widget Library to browse bundled widgets,")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("or drop your own widget folder onto it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 10)
    }

    private func widgetRow(_ row: PreferencesModel.WidgetRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Visible", isOn: Binding(
                get: { !row.hidden },
                set: { model.setHidden(!$0, for: row.id) }
            ))
            HStack(spacing: 14) {
                Toggle("Behind other apps", isOn: Binding(
                    get: { row.inBackground },
                    set: { model.setInBackground($0, for: row.id) }
                ))
                .toggleStyle(.checkbox)
                Toggle("On every screen", isOn: Binding(
                    get: { row.showOnAllScreens },
                    set: { model.setShowOnAllScreens($0, for: row.id) }
                ))
                .toggleStyle(.checkbox)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(row.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - General tab (inset-grouped sections)

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                insetGroupedSection(
                    badge: "folder",
                    badgeColor: .gray,
                    title: "Widgets folder",
                    subtitle: model.widgetDirectory,
                    footer: "Choose a folder or reveal it in Finder. Changing the folder requires a restart."
                ) {
                    HStack(spacing: 10) {
                        Button("Choose…") { model.chooseWidgetDirectory() }
                            .buttonStyle(.bordered)
                        Button("Reveal in Finder") { model.revealWidgetDirectory() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.bottom, 10)

                insetGroupedSection(
                    badge: "keyboard.badge.ellipsis",
                    badgeColor: .orange,
                    title: "Login shell",
                    subtitle: "Run widget commands through your shell profile.",
                    footer: "Some widgets need your shell profile for PATH and aliases. Turning this on restarts the widget server."
                ) {
                    Toggle("Run commands through a login shell", isOn: Binding(
                        get: { model.loginShell },
                        set: { model.setLoginShell($0) }
                    ))
                }
                .padding(.bottom, 10)

                insetGroupedSection(
                    badge: "person.badge.key",
                    badgeColor: .purple,
                    title: "Launch at login",
                    subtitle: "Start Wijeti when you log in.",
                    footer: nil
                ) {
                    Toggle("Start Wijeti at login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                }
                .padding(.bottom, 10)

                insetGroupedSection(
                    badge: "arrow.clockwise",
                    badgeColor: .blue,
                    title: "Refresh and reload",
                    subtitle: "Force a refresh, reload all widgets, or restart the server.",
                    footer: nil
                ) {
                    HStack(spacing: 10) {
                        Button("Refresh All") { model.refreshAll() }
                            .buttonStyle(.bordered)
                        Button("Reload Widgets") { model.reloadWidgets() }
                            .buttonStyle(.bordered)
                        Button("Restart Server") { model.restartServer() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - PreferencesView (compatibility alias)

/// Compatibility type used by code that still references `PreferencesView`.
typealias PreferencesView = WidgetSettingsView

enum WidgetsFooterNote {
    static let text = "Widgets update on their own schedule."
}

// MARK: - Inset-grouped section view (iOS Settings style, adapted for macOS)

/// A section that mimics an iOS `.insetGrouped` list row with a leading icon badge,
/// a title, a subtitle/foreground-secondary value, and an optional footer.
private struct InsetGroupedSection<Content: View>: View {
    let badge: String
    let badgeColor: Color
    let title: String
    let subtitle: String
    let footer: String?
    let content: Content

    init(
        badge: String,
        badgeColor: Color = .blue,
        title: String,
        subtitle: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.badge = badge
        self.badgeColor = badgeColor
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header row: icon badge + title + subtitle (secondary).
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(badgeColor.opacity(0.16))
                    Image(systemName: badge)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(badgeColor)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Divider()
                .padding(.horizontal, 16)

            content
                .padding(.horizontal, 16)
                .padding(.top, 2)

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                Color.clear
                    .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(10)
    }
}

/// Convenience wrapper so callers can write `insetGroupedSection(badge:title:subtitle:footer:content:)`.
private func insetGroupedSection(
    badge: String,
    badgeColor: Color = .blue,
    title: String,
    subtitle: String,
    footer: String? = nil,
    @ViewBuilder content: () -> some View
) -> some View {
    InsetGroupedSection(
        badge: badge,
        badgeColor: badgeColor,
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
                onOpenLibrary: { [weak self] in self?.onOpenLibrary?() }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Wijeti Preferences"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        model.reload()
        probe.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        NSLog("preferences window shown with %d widget(s)", model.rows.count)
    }

    /// Set by the app delegate so "Add Widgets" can open the library window.
    public var onOpenLibrary: (() -> Void)?

    /// Opens the widget library from the preferences window.
    public func openLibrary() { onOpenLibrary?() }
}