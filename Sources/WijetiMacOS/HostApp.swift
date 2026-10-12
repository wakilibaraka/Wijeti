import AppKit
import Foundation
import WijetiCore

/// Mutable launch state shared with the supervisor's argument builder.
///
/// The server reads both of these only when it starts (`--login-shell` and `-d`), so they are
/// held by reference rather than captured by value: a change made while the app runs has to be
/// visible to the *next* launch for the restart to pick it up.
final class ServerFlags {
    var loginShell = false
    var widgetDirectory: URL

    init(widgetDirectory: URL) {
        self.widgetDirectory = widgetDirectory
    }
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

    public private(set) var widgetDirectory: URL
    private let settingsDirectory: URL
    private let pollInterval: TimeInterval
    private let flags: ServerFlags
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
        flags = ServerFlags(widgetDirectory: widgetDirectory)
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
                    "-d", launchFlags.widgetDirectory.path,
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
        // Before the server launches, so its first directory scan already sees the widget.
        installStarterWidgetIfNeeded()
        _ = supervisor.start()
    }

    /// Copies the getting-started widget when the folder is empty.
    ///
    /// A new install otherwise lands on a completely blank desktop: nothing is installed until
    /// the user opens the library and picks something, and a widgets app whose first impression
    /// is "nothing happened" reads as broken. Only the welcome card is copied — which widgets
    /// someone actually wants is theirs to choose.
    public func installStarterWidgetIfNeeded() {
        guard PresetInstaller.entries(in: widgetDirectory).isEmpty else { return }
        do {
            let result = try PresetInstaller.install(
                from: platform.presetsDirectory,
                to: widgetDirectory,
                only: ["GettingStarted.jsx"]
            )
            guard !result.installed.isEmpty else { return }
            NSLog("first launch: installed starter widget %@", result.installed)
            onStatus?("Welcome widget installed")
        } catch {
            NSLog("could not install the starter widget: %@", error.localizedDescription)
        }
    }

    /// Points the widget server at a different folder.
    ///
    /// The directory is a launch argument, so it cannot change under a running server: persist
    /// it, then restart so the new folder is scanned. Widgets in the old folder are left alone —
    /// silently moving or deleting someone's files because they picked a different folder would
    /// be far worse than leaving them where they are.
    public func setWidgetDirectory(_ url: URL) {
        // Resolve before comparing: the panel can hand back `/tmp/x` when the folder the user
        // is already using is `/private/tmp/x`, which is the same folder, not a new one.
        let url = url.canonicalPathURL
        guard url != widgetDirectory.canonicalPathURL else { return }
        widgetDirectory = url
        flags.widgetDirectory = url
        _ = try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        UserDefaults.standard.set(url.path, forKey: AppKitPlatform.widgetDirectoryDefaultsKey)
        onStatus?("Widget folder is now \(url.lastPathComponent) — restarting server")
        supervisor.restart()
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

    // MARK: - Bulk visibility

    /// The widgets that are currently visible (i.e. not hidden).
    public var visibleWidgetIDs: [String] {
        widgetIDs.filter { !settings(for: $0).hidden }
    }

    /// Makes every widget visible now.
    ///
    /// Both bulk actions live here, not in the windows that offer them, so the menu bar,
    /// the library and AppleScript all run the same loop. Each change goes over the socket
    /// as its own `WIDGET_SETTINGS_CHANGED`, and `updateSettings` mirrors it into
    /// `state.settings` as it goes — which is what lets the loop read a consistent `hidden`
    /// value on every iteration.
    public func enableAllVisibleNow() {
        let targets = widgetIDs.filter { settings(for: $0).hidden }
        guard !targets.isEmpty else {
            onStatus?("All widgets are already visible")
            return
        }
        for id in targets {
            setHidden(false, for: id)
        }
        onStatus?("Showing \(targets.count) widget(s)")
    }

    /// Hides every visible widget now.
    public func disableAllNow() {
        let targets = visibleWidgetIDs
        guard !targets.isEmpty else {
            onStatus?("No visible widgets to hide")
            return
        }
        for id in targets {
            setHidden(true, for: id)
        }
        onStatus?("Hid \(targets.count) widget(s)")
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
