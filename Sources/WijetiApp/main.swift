import AppKit
import Foundation
import WijetiCore
import WijetiMacOS

struct Options {
    var serverDirectory: URL?
    var presetsDirectory: URL?
    var widgetDirectory: URL?
    var settingsDirectory: URL?
    var port: Int?
    var pollInterval: TimeInterval = 1.0
    var snapshotDirectory: URL?
    var exitAfterSnapshot = false
    var installPresets = false
    var showPreferences = false
    var showLibrary = false
    /// `--verify-presets <dir>`: preview every bundled preset, write report + PNGs, exit.
    var verifyPresetsDirectory: URL?
    /// `--preview-preset <id>`: preselect a preset when the library opens.
    var previewPresetID: String?

    init(arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let value: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
            // Boolean flags consume only themselves; value flags consume the next
            // argument too. (Advancing blindly by 2 made `--flag --other-flag` drop
            // the second flag.)
            var consumedValue = false
            switch flag {
            case "--server-dir" where value != nil:
                serverDirectory = URL(fileURLWithPath: value!)
                consumedValue = true
            case "--presets-dir" where value != nil:
                presetsDirectory = URL(fileURLWithPath: value!)
                consumedValue = true
            case "--widgets" where value != nil:
                widgetDirectory = URL(fileURLWithPath: value!)
                consumedValue = true
            case "--settings" where value != nil:
                settingsDirectory = URL(fileURLWithPath: value!)
                consumedValue = true
            case "--port" where value != nil:
                port = Int(value!)
                consumedValue = true
            case "--poll-interval" where value != nil:
                pollInterval = Double(value!) ?? 1.0
                consumedValue = true
            case "--snapshot-dir" where value != nil:
                snapshotDirectory = URL(fileURLWithPath: value!)
                consumedValue = true
            case "--verify-presets" where value != nil:
                verifyPresetsDirectory = URL(fileURLWithPath: value!)
                consumedValue = true
            case "--preview-preset" where value != nil:
                previewPresetID = value!
                consumedValue = true
            case "--exit-after-snapshot":
                exitAfterSnapshot = true
            case "--install-presets":
                installPresets = true
            case "--show-preferences":
                showPreferences = true
            case "--show-library":
                showLibrary = true
            default:
                break
            }
            index += consumedValue ? 2 : 1
        }
    }
}

/// The delegate builds every UI object, and those are all main-actor isolated, so the
/// whole delegate is main-actor isolated too. AppKit calls these on the main thread.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private let host: HostApp
    private let tray: TrayMenuController
    private let preferences: PreferencesWindowController
    private let library: WidgetLibraryWindow
    private var snapshotWork: DispatchWorkItem?
    private var snapshotStarted = false
    private var appliedState = false
    private var pendingPreferences = false
    private var pendingLibrary = false
    private var presetVerifier: PresetVerifier?
    private var verifyStarted = false

    init(options: Options) {
        self.options = options

        // Packaged: the server lives in Contents/Resources/release. From `swift run`
        // there is no bundle, so fall back to the repository's server/release.
        let bundledServer = Bundle.main.resourceURL?
            .appendingPathComponent("release", isDirectory: true)
        let fallbackServer: URL
        if let bundledServer, FileManager.default.fileExists(atPath: bundledServer.path) {
            fallbackServer = bundledServer
        } else {
            fallbackServer = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // WijetiApp
                .deletingLastPathComponent()  // Sources
                .deletingLastPathComponent()  // package root
                .appendingPathComponent("server/release", isDirectory: true)
        }

        let platform = AppKitPlatform(
            serverResources: options.serverDirectory ?? fallbackServer,
            presetsDirectory: options.presetsDirectory
        )
        let host = HostApp(
            platform: platform,
            widgetDirectory: options.widgetDirectory ?? platform.widgetDirectory,
            settingsDirectory: options.settingsDirectory ?? platform.preferencesDirectory,
            port: options.port,
            loginShell: UserDefaults.standard.bool(forKey: "loginShell"),
            pollInterval: options.pollInterval
        )
        self.host = host

        tray = TrayMenuController(host: host)
        preferences = PreferencesWindowController(host: host)
        library = WidgetLibraryWindow(
            model: WidgetLibraryModel(host: host, presetsDirectory: platform.presetsDirectory)
        )
        ScriptingBridge.shared.host = host

        super.init()

        tray.onShowPreferences = { [weak self] in self?.preferences.show() }
        tray.onOpenLibrary = { [weak self] in self?.library.show() }
        tray.onQuit = { NSApp.terminate(nil) }
        preferences.onOpenLibrary = { [weak self] in self?.library.show() }
        host.onServerStopped = { [weak self] in self?.tray.refreshStatus() }
        host.onStateChange = { [weak self] (fetched: WidgetStateResponse) in
            guard let self else { return }
            self.appliedState = true
            // The window can only be populated once the server has scanned its widget
            // directory — the first poll can land before that, so wait for a state that
            // actually carries widgets.
            if self.pendingLibrary || self.pendingPreferences, !fetched.widgets.isEmpty {
                self.pendingPreferences = false
                if self.pendingLibrary {
                    self.pendingLibrary = false
                    self.library.show()
                    self.libraryDidShow()
                } else {
                    self.preferences.show()
                }
            }
            self.scheduleSnapshotIfNeeded()
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandler()

        // `--install-presets` is the scriptable equivalent of the tray item's
        // "Install Presets…": copy the bundled presets and quit.
        if options.installPresets {
            host.installPresets()
            NSApp.terminate(nil)
            return
        }

        tray.install()
        NSLog("Wijeti starting; widgets: %@", host.widgetDirectoryURL.path)
        host.start()
        pendingLibrary = options.showLibrary
        pendingPreferences = options.showPreferences
        if pendingPreferences || pendingLibrary {
            // Fallback for an empty widget directory: show the window anyway rather than
            // waiting forever for a state that will never list anything.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.pendingPreferences || self.pendingLibrary else { return }
                let showLibrary = self.pendingLibrary
                self.pendingPreferences = false
                self.pendingLibrary = false
                if showLibrary {
                    self.library.show()
                    self.libraryDidShow()
                } else {
                    self.preferences.show()
                }
            }
        }
    }

    /// Right after the library window is up: honour `--preview-preset`, and kick off
    /// the `--verify-presets` walk once layout has settled.
    private func libraryDidShow() {
        if let id = options.previewPresetID {
            library.selectPreset(id: id)
        }
        guard options.verifyPresetsDirectory != nil, !verifyStarted else { return }
        verifyStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.runPresetVerification()
        }
    }

    /// Walks every bundled preset through the preview pane, writes `report.txt` plus a
    /// PNG per preset and of the whole window, then exits. Dev/CI flag.
    private func runPresetVerification() {
        guard let directory = options.verifyPresetsDirectory else { return }
        let ids = library.bundledPresetIDs()
        guard !ids.isEmpty else {
            NSLog("verify: catalog is empty, nothing to check")
            NSApp.terminate(nil)
            return
        }
        let verifier = PresetVerifier(library: library, outputDirectory: directory)
        presetVerifier = verifier
        verifier.run(presetIDs: ids) { allPassed in
            NSLog("preset verification %@", allPassed ? "passed" : "had failures")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        snapshotWork?.cancel()
        library.shutdown()
        host.stop()
    }

    // MARK: - AppleScript

    /// Backs `<cocoa key="widgets"/>` in Wijeti.sdef: `every widget` resolves to these.
    @objc func widgets() -> [WijetiWidget] {
        host.widgetIDs.map { WijetiWidget(id: $0) }
    }

    /// Tells AppKit to forward the `widgets` key to this delegate, exactly as
    /// `-[UBAppDelegate application:delegateHandlesKey:]` does. It is an optional
    /// `@objc` protocol method rather than an override, so it is implemented without
    /// `override` and answers `false` for every key we do not own.
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        key == "widgets"
    }

    // MARK: - Snapshot verification

    /// `--snapshot-dir` renders every widget window to a PNG: automated proof that widgets
    /// painted, without needing Screen Recording permission.
    private func scheduleSnapshotIfNeeded() {
        guard let directory = options.snapshotDirectory, !snapshotStarted, appliedState else { return }
        snapshotStarted = true
        let work = DispatchWorkItem { [weak self] in self?.writeSnapshots(to: directory) }
        snapshotWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func writeSnapshots(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let windows = host.coordinator.allWindows
        guard !windows.isEmpty else {
            NSLog("snapshot requested but no widget windows are open")
            if options.exitAfterSnapshot { NSApp.terminate(nil) }
            return
        }

        let group = DispatchGroup()
        var written = 0
        for window in windows {
            group.enter()
            window.snapshot { image in
                defer { group.leave() }
                let name = "\(window.layer.rawValue)-screen\(window.screen).png"
                let url = directory.appendingPathComponent(name)
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    NSLog("snapshot failed for %@", name)
                    return
                }
                do {
                    try png.write(to: url)
                    written += 1
                    NSLog("wrote snapshot %@", url.path)
                } catch {
                    NSLog("snapshot write failed: %@", error.localizedDescription)
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            NSLog("wrote %d snapshot(s)", written)
            if self.options.exitAfterSnapshot {
                NSApp.terminate(nil)
            }
        }
    }

    private func installSignalHandler() {
        signal(SIGINT) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
        signal(SIGTERM) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
    }
}

// MARK: - Launch

let options = Options(arguments: Array(CommandLine.arguments.dropFirst()))
let application = NSApplication.shared
// Accessory policy keeps Wijeti out of the Dock, matching the original's LSUIElement
// behaviour while still running from a plain SwiftPM executable.
application.setActivationPolicy(.accessory)
// `AppDelegate` is main-actor isolated, and `main.swift` is top-level code, which the
// compiler treats as nonisolated — so hop explicitly rather than dropping the isolation.
MainActor.assumeIsolated {
    let delegate = AppDelegate(options: options)
    application.delegate = delegate
}
application.run()
