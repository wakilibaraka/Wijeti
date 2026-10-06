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

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    @ObservedObject var probe: PermissionProbe
    @ObservedObject var sources: DataSourceSettings
    var onOpenLibrary: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case widgets, general, permissions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .widgets: return "Widgets"
            case .general: return "General"
            case .permissions: return "Permissions"
            }
        }
    }

    @State private var tab: Tab = .widgets

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Wijeti")
                    .font(.title2.bold())
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch tab {
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

    private var widgetsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installed widgets")
                        .font(.headline)
                    Text(model.rows.isEmpty
                         ? "Nothing installed yet."
                         : "\(model.rows.count) installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Widgets…", action: onOpenLibrary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if model.rows.isEmpty {
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
                    Button("Open Widget Library…", action: onOpenLibrary)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.rows) { row in
                            widgetRow(row)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func widgetRow(_ row: PreferencesModel.WidgetRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Widgets folder")
                    .font(.callout.weight(.medium))
                Text(model.widgetDirectory)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 10) {
                    Button("Choose…") { model.chooseWidgetDirectory() }
                    Button("Reveal in Finder") { model.revealWidgetDirectory() }
                }

                Divider()

                Toggle("Run widget commands through a login shell", isOn: Binding(
                    get: { model.loginShell },
                    set: { model.setLoginShell($0) }
                ))
                Text("Some widgets need your shell profile for PATH and aliases. "
                     + "Turning this on restarts the widget server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Start Wijeti at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))

                Divider()

                HStack(spacing: 10) {
                    Button("Refresh All") { model.refreshAll() }
                    Button("Reload Widgets") { model.reloadWidgets() }
                    Button("Restart Server") { model.restartServer() }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum WidgetsFooterNote {
    static let text = "Widgets update on their own schedule."
}

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
            let view = PreferencesView(
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
            window.setContentSize(NSSize(width: 520, height: 620))
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
}
