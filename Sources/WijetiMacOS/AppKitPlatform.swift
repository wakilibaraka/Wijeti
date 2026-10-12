import AppKit
import Foundation
import WijetiCore

/// The macOS implementation of `HostPlatform`.
///
/// Paths live under `~/Library/Application Support/Wijeti`. The Objective-C original used
/// `…/Übersicht/widgets` for widgets and `…/tracesOf.Uebersicht` for settings; the widgets
/// directory is migrated on first run so existing widgets survive the rename, but new
/// settings are written to Wijeti's own directory.
public final class AppKitPlatform: HostPlatform {
    private let serverResources: URL
    private let presetsOverride: URL?

    public init(serverResources: URL, presetsDirectory: URL? = nil) {
        self.serverResources = serverResources
        self.presetsOverride = presetsDirectory
    }

    public var serverResourcesDirectory: URL { serverResources }

    /// The `localnode` wrapper the supervisor spawns.
    public var serverExecutable: URL {
        serverResources.appendingPathComponent("localnode")
    }

    /// The browserified widget server.
    public var serverScript: URL {
        serverResources.appendingPathComponent("server.js")
    }

    public var preferencesDirectory: URL {
        applicationSupport
            .appendingPathComponent("Wijeti", isDirectory: true)
    }

    /// Settings file handed to the server via `-s`; the host reads and writes the same file.
    public var widgetSettingsFile: URL {
        preferencesDirectory.appendingPathComponent("WidgetSettings.json")
    }

    /// Where the widget server is told to look (`-d`).
    ///
    /// A folder chosen in settings wins over the default. It has to be resolvable before the
    /// server process is launched, which is why it is read from defaults here rather than
    /// being threaded through the UI.
    public static let widgetDirectoryDefaultsKey = "WidgetDirectoryPath"

    public var widgetDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: Self.widgetDirectoryDefaultsKey),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).canonicalPathURL
        }
        return applicationSupport
            .appendingPathComponent("Wijeti/widgets", isDirectory: true)
            .canonicalPathURL
    }

    /// Where the pre-rename app kept widgets.
    public var legacyWidgetDirectory: URL {
        applicationSupport
            .appendingPathComponent("Übersicht/widgets", isDirectory: true)
    }

    public var presetsDirectory: URL {
        if let presetsOverride { return presetsOverride }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("presets", isDirectory: true) {
            return bundled
        }
        // No bundle (a bare executable): assume it was started from the repo root.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/presets", isDirectory: true)
    }

    public var initialServerPort: Int { 41416 }

    public func makeProcessLauncher() -> ServerProcessLaunching {
        AppKitProcessLauncher()
    }

    public func openExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copies widgets from the pre-rename directory the first time Wijeti runs.
    /// Existing files in the destination are never overwritten.
    @discardableResult
    public func migrateLegacyWidgetsIfNeeded() throws -> Int {
        let destination = widgetDirectory
        let existingWidgets = Self.jsxWidgets(in: destination)
        guard existingWidgets.isEmpty else { return 0 }

        let legacy = legacyWidgetDirectory
        let legacyWidgets = Self.jsxWidgets(in: legacy)
        guard !legacyWidgets.isEmpty else { return 0 }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in legacyWidgets {
            try? FileManager.default.copyItem(
                at: legacy.appendingPathComponent(name),
                to: destination.appendingPathComponent(name)
            )
        }
        NSLog("migrated %d widget(s) from %@", legacyWidgets.count, legacy.logPath)
        return legacyWidgets.count
    }

    private var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Names of the `.jsx` files in a directory, empty when the directory is absent.
    public static func jsxWidgets(in directory: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter { $0.hasSuffix(".jsx") }.sorted()
    }
}
