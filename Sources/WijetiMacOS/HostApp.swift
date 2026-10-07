import AppKit
import Foundation
import WijetiCore

/// Mutable launch flags shared with the supervisor's argument builder.
final class ServerFlags {
    var loginShell = false
}

/// Everything the UI layers (tray menu, preferences, AppleScript) drive.
///
/// Settings are deliberately **not** written to `WidgetSettings.json` here: the widget
/// server owns that file and rewrites it on every store change. Instead changes go over
/// the message bus as `WIDGET_SETTINGS_CHANGED`, exactly as the server itself does when it
/// replays settings at startup — one writer, and every open widget re-renders.
public final class HostApp {
    public let platform: AppKitPlatform
    public let coordinator: ScreenCoordinator
    public let supervisor: ServerSupervisor

    public private(set) var state = WidgetStateResponse(widgets: [:], settings: [:], screens: [])
    public private(set) var loginShell: Bool
    public private(set) var port: Int?

    public var onStateChange: ((WidgetStateResponse) -> Void)?
    public var onServerStarted: ((Int) -> Void)?
    public var onServerStopped: (() -> Void)?
    public var onStatus: ((String) -> Void)?

    private let widgetDirectory: URL
    private let settingsDirectory: URL
    private let pollInterval: TimeInterval
    private let flags = ServerFlags()
    private let socket = HostSocket()
    private var pollTimer: Timer?

    public init(
        platform: AppKitPlatform,
        widgetDirectory: URL,
        settingsDirectory: URL,
        port requestedPort: Int?,
        loginShell: Bool,
        pollInterval: TimeInterval
    ) {
        self.platform = platform
        self.widgetDirectory = widgetDirectory
        self.settingsDirectory = settingsDirectory
        self.pollInterval = pollInterval
        self.loginShell = loginShell
        flags.loginShell = loginShell

        coordinator = ScreenCoordinator(
            argvPath: platform.serverExecutable.path,
            openExternal: { platform.openExternal($0) }
        )

        let serverResources = platform
        let launchFlags = flags
        supervisor = ServerSupervisor(
            basePort: requestedPort ?? platform.initialServerPort,
            executable: platform.serverExecutable,
            argumentsForPort: { port in
                [
                    serverResources.serverScript.path,
                    "-d", widgetDirectory.path,
                    "-p", String(port),
                    "-s", settingsDirectory.path,
                ] + (launchFlags.loginShell ? ["--login-shell"] : [])
            },
            launcher: platform.makeProcessLauncher(),
            log: { message in NSLog("%@", message) }
        )

        supervisor.onServerStarted = { [weak self] port in
            self?.serverDidStart(port: port)
        }
        supervisor.onServerStopped = { [weak self] in
            guard let self else { return }
            self.coordinator.shutdown()
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            self.socket.close()
            self.port = nil
            self.onServerStopped?()
        }
    }

    // MARK: - Lifecycle

    public func start() {
        _ = try? platform.migrateLegacyWidgetsIfNeeded()
        _ = try? FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)
        _ = supervisor.start()
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        socket.close()
        coordinator.shutdown()
        supervisor.stop()
    }

    /// The server reads `--login-shell` at launch, so toggling this restarts it.
    public func setLoginShell(_ enabled: Bool) {
        guard enabled != loginShell else { return }
        loginShell = enabled
        flags.loginShell = enabled
        onStatus?("Login shell \(enabled ? "on" : "off") — restarting server")
        supervisor.restart()
    }

    public func restartServer() {
        supervisor.restart()
    }

    private func serverDidStart(port: Int) {
        self.port = port
        onStatus?("Server running on port \(port)")
        socket.open(url: URL(string: "ws://127.0.0.1:\(port)/")!)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshState(port: port)
        }
        refreshState(port: port)
        onServerStarted?(port)
    }

    private func refreshState(port: Int) {
        let url = URL(string: "http://127.0.0.1:\(port)/state/")!
        Task { [weak self] in
            guard let self else { return }
            guard let fetched = try? await WidgetStateResponse.fetch(from: url) else { return }
            await MainActor.run {
                self.state = fetched
                self.coordinator.apply(state: fetched, port: port)
                self.onStateChange?(fetched)
            }
        }
    }

    // MARK: - Widget actions

    public var widgetIDs: [String] {
        state.widgets.keys.sorted()
    }

    public func settings(for widgetID: String) -> WidgetSettings {
        state.settings(for: widgetID)
    }

    /// Asks every open widget to re-run its command now.
    public func refreshWidgets(ids: [String]? = nil) {
        let targets = ids ?? widgetIDs
        guard !targets.isEmpty else {
            onStatus?("No widgets to refresh")
            return
        }
        for id in targets {
            socket.send(["type": "WIDGET_WANTS_REFRESH", "payload": id])
        }
        onStatus?("Refreshed \(targets.count) widget(s)")
    }

    public func reloadWidgets() {
        coordinator.reloadAll()
        onStatus?("Reloaded widgets")
    }

    public func updateSettings(
        _ widgetID: String,
        _ mutate: @escaping (inout WidgetSettings) -> Void
    ) {
        var settings = self.settings(for: widgetID)
        mutate(&settings)
        socket.send([
            "type": "WIDGET_SETTINGS_CHANGED",
            "payload": ["id": widgetID, "settings": settings.dictionary],
        ])
        // Mirror the change locally so `set hidden of widget 1 to true` followed by a read
        // in the same AppleScript event sees the new value; the next poll replaces this with
        // the server's own copy, which is the one that owns the file.
        state.settings[widgetID] = settings
        onStatus?("Updated \(widgetID)")
    }

    public func setHidden(_ hidden: Bool, for widgetID: String) {
        updateSettings(widgetID) { $0.hidden = hidden }
    }

    public func installPresets() {
        do {
            let result = try PresetInstaller.install(
                from: platform.presetsDirectory,
                to: widgetDirectory
            )
            let message = result.installed.isEmpty
                ? "Presets already installed (\(result.skipped.count) present)"
                : "Installed \(result.installed.count) preset(s)"
            onStatus?(message)
            NSLog("presets: installed %@, already present %@", result.installed, result.skipped)
        } catch {
            onStatus?("Preset install failed: \(error.localizedDescription)")
        }
    }

    public var widgetDirectoryURL: URL { widgetDirectory }
    public var settingsDirectoryURL: URL { settingsDirectory }

    public func revealWidgetDirectory() {
        try? FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)
        platform.revealInFinder(widgetDirectory)
    }

    public func visitGallery() {
        if let url = URL(string: "https://github.com/felixhageloh/uebersicht-widgets") {
            platform.openExternal(url)
        }
    }
}
