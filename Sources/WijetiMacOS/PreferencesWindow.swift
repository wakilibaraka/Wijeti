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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Wijeti")
                .font(.title2.bold())
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 4)

            Text(model.widgetDirectory)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 20)

            HStack(spacing: 10) {
                Button("Choose…") { model.chooseWidgetDirectory() }
                Button("Reveal in Finder") { model.revealWidgetDirectory() }
                Button("Install Presets…") { model.installPresets() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Divider().padding(.vertical, 14)

            Text("Widgets")
                .font(.headline)
                .padding(.horizontal, 20)

            if model.rows.isEmpty {
                Text("No widgets found in the widget directory.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle("Visible", isOn: Binding(
                                    get: { !row.hidden },
                                    set: { model.setHidden(!$0, for: row.id) }
                                ))
                                Toggle("Behind other apps", isOn: Binding(
                                    get: { row.inBackground },
                                    set: { model.setInBackground($0, for: row.id) }
                                ))
                                Toggle("On every screen", isOn: Binding(
                                    get: { row.showOnAllScreens },
                                    set: { model.setShowOnAllScreens($0, for: row.id) }
                                ))
                            }
                            .padding(.bottom, 4)
                            Divider()
                            Text(row.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 8)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(maxHeight: 320)
            }

            Divider().padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Run widget commands through a login shell", isOn: Binding(
                    get: { model.loginShell },
                    set: { model.setLoginShell($0) }
                ))
                Toggle("Start Wijeti at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                HStack(spacing: 10) {
                    Button("Refresh All") { model.refreshAll() }
                    Button("Reload Widgets") { model.reloadWidgets() }
                    Button("Restart Server") { model.restartServer() }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 16)
        }
        .frame(width: 460)
    }
}

/// Hosts the SwiftUI preferences window.
public final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: PreferencesModel

    public init(host: HostApp) {
        model = PreferencesModel(host: host)
        super.init()
    }

    public func show() {
        if window == nil {
            NSLog("opening preferences window")
            let hosting = NSHostingController(rootView: PreferencesView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Wijeti Preferences"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        NSLog("preferences window shown with %d widget(s)", model.rows.count)
    }
}
