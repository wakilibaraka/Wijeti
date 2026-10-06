import AppKit
import Foundation
import WijetiCore

/// Renders a bundled preset for previewing without installing it: a private, throwaway
/// widget server pointed at a scratch directory that holds only the selected preset,
/// plus the same widget client the desktop uses. The real widget directory, settings,
/// and running server are never touched — swap the selection and the server's file
/// watcher re-bundles in place.
@MainActor
final class WidgetPreviewController {
    let webViewController: WidgetWebViewController

    var onStatus: ((String) -> Void)?
    var onReadyChange: ((Bool) -> Void)?

    private let platform: AppKitPlatform
    private let loginShell: () -> Bool
    private let root: URL
    private let widgetsDirectory: URL
    private let settingsDirectory: URL

    private var supervisor: ServerSupervisor?
    private var port: Int?
    private var selectedID: String?
    private var selectedTitle = ""
    private var hasLoadedPage = false

    init(platform: AppKitPlatform, loginShell: @escaping () -> Bool) {
        self.platform = platform
        self.loginShell = loginShell
        // Deliberately *not* the temp directory: `/var/folders` is a symlink to
        // `/private/var/folders`, so the server's file watcher reports event paths that
        // do not string-match the `-d` root — widget ids then gain a `private-` prefix
        // and removals never match. A caches path has no such mismatch.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base
            .appendingPathComponent("Wijeti", isDirectory: true)
            .appendingPathComponent("Preview-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        self.widgetsDirectory = root.appendingPathComponent("widgets", isDirectory: true)
        self.settingsDirectory = root.appendingPathComponent("settings", isDirectory: true)
        webViewController = WidgetWebViewController(argvPath: platform.serverExecutable.path)
        webViewController.onOpenExternal = { platform.openExternal($0) }
    }

    // MARK: - Selection

    /// Selects a preset to preview, starting the private server on first use.
    func show(_ preset: Preset, from presetsDirectory: URL) {
        let source = presetsDirectory.appendingPathComponent(preset.id)
        guard FileManager.default.fileExists(atPath: source.path) else {
            onStatus?("Preset missing: \(preset.id)")
            return
        }
        selectedID = preset.id
        selectedTitle = preset.title
        do {
            try prepareScratchDirectories()
            try copyPreset(named: preset.id, from: source)
        } catch {
            onStatus?("Preview failed: \(error.localizedDescription)")
            return
        }
        if supervisor != nil, let port {
            // The server watches the scratch directory, so the copy above is enough:
            // the client swaps widgets live, without a reload.
            onStatus?(hasLoadedPage ? "Previewing \(preset.title)" : "Loading \(preset.title)…")
            if !hasLoadedPage { loadPage(port: port) }
        } else {
            onStatus?("Starting preview…")
            startServer()
        }
    }

    /// Restarts the preview after the library window was closed (which stops it):
    /// the caller re-issues `show` with its stored selection.

    func stop() {
        supervisor?.stop()
        supervisor = nil
        port = nil
        hasLoadedPage = false
        selectedID = nil
        try? FileManager.default.removeItem(at: root)
        onReadyChange?(false)
        onStatus?("Preview stopped")
    }

    // MARK: - Private server

    private func startServer() {
        guard supervisor == nil else { return }
        // Resolve symlinks so the `-d` root string-matches every path the watcher
        // reports (see the init note); ids and removals then line up exactly.
        let widgets = widgetsDirectory.resolvingSymlinksInPath().path
        let settings = settingsDirectory.resolvingSymlinksInPath().path
        let script = platform.serverScript.path
        let loginShell = self.loginShell
        let supervisor = ServerSupervisor(
            // Offset from the main server's range so the two port walks never cross.
            basePort: platform.initialServerPort + 100,
            executable: platform.serverExecutable,
            argumentsForPort: { port in
                [script, "-d", widgets, "-p", String(port), "-s", settings]
                    + (loginShell() ? ["--login-shell"] : [])
            },
            launcher: platform.makeProcessLauncher(),
            log: { message in NSLog("%@", message) }
        )
        supervisor.onServerStarted = { [weak self] port in
            guard let self else { return }
            self.port = port
            guard self.selectedID != nil else { return }
            if self.hasLoadedPage {
                self.onStatus?("Previewing \(self.selectedTitle)")
            }
            self.loadPage(port: port)
        }
        supervisor.onServerStopped = { [weak self] in
            self?.port = nil
        }
        self.supervisor = supervisor
        _ = supervisor.start()
    }

    private func loadPage(port: Int) {
        webViewController.onLoadFinished = { [weak self] in
            guard let self else { return }
            self.hasLoadedPage = true
            self.onReadyChange?(true)
            self.onStatus?("Previewing \(self.selectedTitle)")
        }
        webViewController.onLoadFailure = { [weak self] error in
            self?.onStatus?("Preview couldn't load: \(error.localizedDescription)")
        }
        webViewController.load(url: URL(string: "http://127.0.0.1:\(port)/1/foreground")!)
    }

    // MARK: - Scratch directory

    private func prepareScratchDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: widgetsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    }

    /// Exactly one preset lives in the scratch widget directory: clearing it first
    /// guarantees the preview shows only the selection (and the watcher sees the swap).
    private func copyPreset(named id: String, from source: URL) throws {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(atPath: widgetsDirectory.path)) ?? [] {
            try fm.removeItem(at: widgetsDirectory.appendingPathComponent(entry))
        }
        try fm.copyItem(at: source, to: widgetsDirectory.appendingPathComponent(id))
    }
}
