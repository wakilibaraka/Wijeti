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
    /// `--capture-ui <dir>`: render the library and settings windows to PNGs, then exit.
    var captureUIDirectory: URL?

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
                // Canonical for the same reason the widget directory is: this path is the root
                // the preview server derives widget ids against, so a symlinked library would
                // preview under a different id than the library lists it under.
                presetsDirectory = URL(fileURLWithPath: value!).canonicalPathURL
                consumedValue = true
            case "--widgets" where value != nil:
                widgetDirectory = URL(fileURLWithPath: value!).canonicalPathURL
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
            case "--capture-ui" where value != nil:
                captureUIDirectory = URL(fileURLWithPath: value!)
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
    private var onboarding: OnboardingWindowController
    private var presetVerifier: PresetVerifier?
    private var verifyStarted = false
    private var uiCaptureStarted = false

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
        onboarding = OnboardingWindowController(
            host: host,
            allowsCompletedOnboarding: options.captureUIDirectory != nil
        )
        ScriptingBridge.shared.host = host

        super.init()

        tray.onShowPreferences = { [weak self] in self?.preferences.show() }
        tray.onOpenLibrary = { [weak self] in self?.library.show() }
        tray.onAddWidgets = { [weak self] in self?.library.addWidgets() }
        tray.onQuit = { NSApp.terminate(nil) }
        preferences.onOpenLibrary = { [weak self] in self?.library.show() }
        // Settings → General → Show Welcome Tour. Replaying the tour must not depend on the
        // completion flag, which is what keeps it from reappearing on its own.
        preferences.onShowOnboarding = { [weak self] in self?.onboarding.show(force: true) }
        host.onServerStopped = { [weak self] in
            self?.tray.refreshStatus()
            self?.preferences.refreshIfVisible()
        }
        host.onServerStarted = { [weak self] _ in self?.tray.refreshStatus() }
        host.onStateChange = { [weak self] (fetched: WidgetStateResponse) in
            guard let self else { return }
            self.appliedState = true
            // The tray used to claim `onStateChange` for itself, which displaced this handler
            // entirely. Keeping the menu in sync is now this handler's job.
            self.tray.refreshStatus()
            self.preferences.refreshIfVisible()
            // The library's contents come from the server, whose first state can land after
            // the window was already opened. Refresh it only while it is actually on screen.
            if self.library.window?.isVisible == true {
                self.library.model.refreshInstalledFromHost()
            }
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
        // "Install Bundled Widgets": copy the bundled presets and quit.
        if options.installPresets {
            host.installPresets()
            NSApp.terminate(nil)
            return
        }

        installMainMenu()
        tray.install()
        NSLog("Wijeti starting; widgets: %@", host.widgetDirectoryURL.path)
        // The library is only as good as this path: if it resolves somewhere without a
        // Catalog.json the window opens empty, which is indistinguishable from "no bundled
        // widgets" unless the resolved path and count are on the record.
        NSLog(
            "widget library: %@ (%d bundled preset(s))",
            host.platform.presetsDirectory.path,
            PresetCatalog.load(from: host.platform.presetsDirectory).presets.count
        )
        NSLog(
            "options: snapshotDir=%@ exitAfterSnapshot=%@ captureUI=%@",
            options.snapshotDirectory?.path ?? "-",
            options.exitAfterSnapshot ? "yes" : "no",
            options.captureUIDirectory?.path ?? "-"
        )
        host.start()

        // First-launch onboarding, before anything else. It is the intro surface, so it
        // should be the first thing the user sees, and it clears itself on dismiss.
        onboarding.show()

        // First launch only. The onboarding guard is the completion flag, which is only written
        // on dismiss — so at this point "onboarding is on screen" and "the flag is unset" are
        // the same question.
        if !UserDefaults.standard.bool(forKey: OnboardingWindowController.didCompleteKey) {
            tray.pulseIcon()
        }

        // `--capture-ui` is a one-shot dev flag: show both windows, draw them to PNGs, exit.
        // It takes precedence over `--show-library`, which it implies.
        if options.captureUIDirectory != nil {
            runUICapture()
            return
        }

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

    @objc func openLibrary() {
        library.show()
    }

    // MARK: - Main menu

    /// A minimal main menu.
    ///
    /// Wijeti is an accessory app (`LSUIElement`) and has never had a menu bar, so the key
    /// equivalents on the status-bar menu did nothing until the user opened that menu. AppKit
    /// routes key equivalents through `NSApp.mainMenu` whether or not the bar is drawn, so
    /// installing one is what makes `Cmd-R` reload widgets from any window.
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(showPreferences(_:)),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Close Window",
            action: #selector(closeKeyWindow(_:)),
            keyEquivalent: "w"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Wijeti",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        let appItem = NSMenuItem()
        appItem.submenu = appMenu

        let widgetsMenu = NSMenu(title: "Widgets")
        widgetsMenu.addItem(
            withTitle: "Widget Library",
            action: #selector(showLibrary(_:)),
            keyEquivalent: "l"
        )
        widgetsMenu.addItem(
            withTitle: "Open Widgets Folder",
            action: #selector(openWidgetFolder(_:)),
            keyEquivalent: "o"
        )
        widgetsMenu.addItem(.separator())
        addMenuItem(
            to: widgetsMenu,
            title: "Refresh All Widgets",
            action: #selector(refreshAllWidgets(_:)),
            key: "r",
            modifiers: [.command, .shift]
        )
        addMenuItem(
            to: widgetsMenu,
            title: "Reload Widgets",
            action: #selector(reloadAllWidgets(_:)),
            key: "r",
            modifiers: [.command]
        )
        widgetsMenu.addItem(.separator())
        // Shift-modified on purpose: plain Cmd-A is Select All and Cmd-H is Hide App, and the
        // menu bar is not visible in an accessory app to explain why they stopped working.
        addMenuItem(
            to: widgetsMenu,
            title: "Show All Widgets",
            action: #selector(showAllWidgets(_:)),
            key: "a",
            modifiers: [.command, .shift]
        )
        addMenuItem(
            to: widgetsMenu,
            title: "Hide All Widgets",
            action: #selector(hideAllWidgets(_:)),
            key: "h",
            modifiers: [.command, .shift]
        )
        let widgetsItem = NSMenuItem()
        widgetsItem.submenu = widgetsMenu

        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(widgetsItem)
        NSApp.mainMenu = main
        NSLog(
            "main menu installed: %@",
            main.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }

    private func addMenuItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
    }

    // Menu item targets stay `nil` so AppKit resolves them through the responder chain, which
    // ends here at the app delegate — the same route the status menu already relies on.
    @objc private func showPreferences(_ sender: Any?) { preferences.show() }
    @objc private func showLibrary(_ sender: Any?) { library.show() }
    @objc private func openWidgetFolder(_ sender: Any?) { host.revealWidgetDirectory() }
    @objc private func closeKeyWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(nil) }
    @objc private func refreshAllWidgets(_ sender: Any?) { host.refreshWidgets() }
    @objc private func reloadAllWidgets(_ sender: Any?) { host.reloadWidgets() }
    @objc private func showAllWidgets(_ sender: Any?) { host.enableAllVisibleNow() }
    @objc private func hideAllWidgets(_ sender: Any?) { host.disableAllNow() }

    // MARK: - UI capture (`--capture-ui`)

    /// Shows the library, settings and onboarding windows, renders them to PNGs in light and
    /// dark appearance and at regular and compact widths, then quits. `cacheDisplay` reads the
    /// view hierarchy rather than the display, so this needs no Screen Recording grant — unlike
    /// `screencapture`.
    ///
    /// Capturing each window in both appearances and at a tiled width is what makes the design
    /// review evidence rather than an assertion: the same view code has to read correctly on a
    /// system surface, in dark mode, and in a half-screen window.
    private func runUICapture() {
        guard let directory = options.captureUIDirectory, !uiCaptureStarted else { return }
        uiCaptureStarted = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library.show()
        preferences.show()
        onboarding.show()
        NSLog("ui capture: windows shown, drawing in 3s")
        // Let the split view settle and the preview server come up before drawing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            NSLog("ui capture: library chrome — %@", self.library.chromeSummary)
            NSLog("ui capture: settings chrome — %@", self.preferences.chromeSummary)

            var captures: [(name: String, image: NSImage?)] = []
            // Let SwiftUI lay out and draw after an appearance or size change before reading
            // the view hierarchy back.
            func settle(_ seconds: TimeInterval = 0.7) {
                RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            }

            let regularSize = self.library.window?.contentLayoutRect.size ?? NSSize(width: 1180, height: 760)
            // Named appearances rather than `nil`: the machine's own setting decides what
            // `nil` resolves to, so a dark-mode Mac would produce two dark passes and no
            // light one. `.aqua` and `.darkAqua` pin each pass to what it claims to be.
            let appearances: [(suffix: String, appearance: NSAppearance?)] = [
                (suffix: "light", appearance: NSAppearance(named: .aqua)),
                (suffix: "dark", appearance: NSAppearance(named: .darkAqua)),
            ]
            for appearance in appearances {
                NSApp.appearance = appearance.appearance
                settle()

                // Regular width: sidebar + gallery + preview.
                NSLog("ui capture: settings layout (regular) — %@", self.preferences.layoutSummary)
                captures.append(("library-\(appearance.suffix).png", self.library.snapshotWindowImage()))
                for tab in PreferencesModel.Tab.allCases {
                    self.preferences.select(tab: tab)
                    settle(0.5)
                    captures.append((
                        "settings-\(tab.rawValue)-\(appearance.suffix).png",
                        self.preferences.snapshotWindowImage()
                    ))
                }
                captures.append(("onboarding-\(appearance.suffix).png", self.onboarding.snapshotWindowImage()))

                // A half-screen tile: the same views have to stay usable at the window minimums.
                // The layout needs a couple of passes to settle at the new size — the hosted
                // preview web view keeps its old frame for a beat otherwise, and capture reads
                // the frames it finds.
                self.library.window?.setContentSize(AppMetrics.libraryMinimum)
                self.preferences.resizeForCapture(
                    width: AppMetrics.settingsMinimum.width,
                    height: AppMetrics.settingsMinimum.height
                )
                settle(2)
                NSLog("ui capture: compact library layout — %@", self.library.previewFrameSummary)
                let selected = self.library.model.selectedPreset
                self.library.model.selectedPreset = nil
                settle(0.8)
                captures.append(("library-compact-\(appearance.suffix).png", self.library.snapshotWindowImage()))
                if let selected {
                    self.library.model.select(selected)
                    settle(1.5)
                    NSLog("ui capture: compact preview layout — %@", self.library.previewFrameSummary)
                    captures.append(("library-compact-preview-\(appearance.suffix).png", self.library.snapshotWindowImage()))
                }
                self.preferences.select(tab: .widgets)
                settle(0.5)
                captures.append(("settings-compact-\(appearance.suffix).png", self.preferences.snapshotWindowImage()))
                NSLog("ui capture: settings layout — %@", self.preferences.layoutSummary)

                self.library.window?.setContentSize(regularSize)
                self.preferences.resizeForCapture(width: 860, height: 640)
                settle(0.5)
            }

            NSApp.appearance = nil
            var written = 0
            for capture in captures {
                guard let image = capture.image else {
                    NSLog("ui capture: nothing to draw for %@", capture.name)
                    continue
                }
                if WindowSnapshot.writePNG(
                    image,
                    to: directory.appendingPathComponent(capture.name)
                ) {
                    written += 1
                }
            }
            NSLog("ui capture: wrote %d of %d", written, captures.count)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Snapshot verification

    /// `--snapshot-dir` renders every widget window to a PNG: automated proof that widgets
    /// painted, without needing Screen Recording permission.
    private func scheduleSnapshotIfNeeded() {
        guard let directory = options.snapshotDirectory, !snapshotStarted, appliedState else { return }
        snapshotStarted = true
        NSLog("snapshot: scheduled in 5s — %@", directory.path)
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

        NSLog("snapshot: rendering %d widget window(s)", windows.count)
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
