import AppKit
import WijetiCore

/// Which desktop layer a window sits in.
///
/// The widget client reads screen and layer straight out of its own URL
/// (`/<screen>/<layer>`, see `client.coffee` and `render.js`), then renders only the
/// widgets whose `inBackground` setting matches that layer and that are visible on that
/// screen. So the host owns exactly two windows per screen and lets the client decide what
/// goes in them — the same arrangement as `UBWindowsController`.
public enum WidgetLayer: String, CaseIterable, Sendable {
    case background
    case foreground

    public var windowType: DesktopWindowType {
        switch self {
        case .background: return .background
        case .foreground: return .foreground
        }
    }
}

public final class ScreenCoordinator {
    public struct WidgetWindow {
        public let screen: Int
        public let layer: WidgetLayer
        public let window: DesktopWindow
        let controller: WidgetWebViewController

        /// Renders the widget web view to an image — the automated proof that a widget
        /// actually painted, without needing Screen Recording permission.
        public func snapshot(completion: @escaping (NSImage?) -> Void) {
            controller.snapshot(completion: completion)
        }
    }

    private let argvPath: String
    private let openExternal: (URL) -> Void
    private var windows: [String: WidgetWindow] = [:]
    private var lastPort: Int?
    /// Signature of the last applied screen layout, so a state poll that changes nothing can
    /// be ignored. See `apply(port:)`.
    private var lastLayout: [CGRect] = []
    private var lastPortApplied: Int?
    private var screenObserver: NSObjectProtocol?

    public init(argvPath: String, openExternal: @escaping (URL) -> Void) {
        self.argvPath = argvPath
        self.openExternal = openExternal
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let port = self.lastPort else { return }
            self.apply(port: port)
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    public func apply(state: WidgetStateResponse, port: Int) {
        lastPort = port
        apply(port: port)
    }

    /// Reconciles the desktop windows with the current screens and layers.
    ///
    /// This is driven by the 1 Hz state poll, but its only inputs are the screen layout and the
    /// server port — `coordinator.apply(state:port:)` ignores the state entirely. Framing,
    /// ordering and re-compositing two screen-sized transparent surfaces every single second
    /// was therefore pure waste, and re-fronting the windows on a timer can fight the user’s
    /// own window ordering. A changed layout or port is what actually requires the work.
    private func apply(port: Int) {
        let screens = NSScreen.screens
        let layout = screens.map(\.frame)
        guard layout != lastLayout || port != lastPortApplied else { return }
        // Existing web views point at the old server; rebuild them rather than leaving them dead.
        if let previous = lastPortApplied, previous != port {
            closeAllWindows()
        }
        lastLayout = layout
        lastPortApplied = port
        var wanted: [String: WidgetWindow] = [:]

        for (index, screen) in screens.enumerated() {
            let screenID = index + 1
            for layer in WidgetLayer.allCases {
                let key = "\(screenID)-\(layer.rawValue)"
                let entry: WidgetWindow
                if let existing = windows[key] {
                    // Only redraw when the geometry actually moved.
                    if existing.window.frame != screen.frame {
                        existing.window.setFrame(screen.frame, display: true)
                    }
                    entry = existing
                } else {
                    let window = DesktopWindow(frame: screen.frame)
                    window.apply(type: layer.windowType)
                    let controller = WidgetWebViewController(argvPath: argvPath)
                    controller.webView.autoresizingMask = [.width, .height]
                    controller.webView.frame = screen.frame
                    controller.onOpenExternal = openExternal
                    window.contentView = controller.webView
                    controller.load(
                        url: URL(string: "http://127.0.0.1:\(port)/\(screenID)/\(layer.rawValue)")!,
                        in: window
                    )
                    entry = WidgetWindow(
                        screen: screenID,
                        layer: layer,
                        window: window,
                        controller: controller
                    )
                    // A new window has to be ordered in; an existing one already is.
                    window.orderFrontRegardless()
                }
                wanted[key] = entry
            }
        }

        for (key, entry) in windows where wanted[key] == nil {
            entry.window.orderOut(nil)
            entry.window.close()
        }
        windows = wanted
        NSLog(
            "screens synced: %d window(s) across %d screen(s)",
            wanted.count,
            screens.count
        )
    }

    public var allWindows: [WidgetWindow] {
        windows.values.sorted {
            ($0.screen, $0.layer.rawValue) < ($1.screen, $1.layer.rawValue)
        }
    }

    /// Re-applies window geometry and forces a repaint — used after a wallpaper or Space
    /// change, matching `-[UBWindowsController redraw]`.
    public func refresh() {
        guard let lastPort else { return }
        // Forget what was applied so the full pass runs even though the layout is unchanged.
        lastLayout = []
        apply(port: lastPort)
        for entry in windows.values {
            entry.controller.forceRedraw()
        }
    }

    /// Applies the developer-mode setting to windows that already exist.
    public func setInspectable(_ enabled: Bool) {
        for entry in windows.values { entry.controller.webView.isInspectable = enabled }
    }

    public func reloadAll() {
        for entry in windows.values {
            entry.controller.reload()
        }
    }

    public func shutdown() {
        closeAllWindows()
        // Forget what was applied: the next server may come back on the same port with the
        // same screens, and the guard in `apply(port:)` would otherwise leave the desktop empty.
        lastLayout = []
        lastPortApplied = nil
    }

    private func closeAllWindows() {
        for entry in windows.values {
            entry.controller.shutdown()
            entry.window.orderOut(nil)
            entry.window.close()
        }
        windows.removeAll()
    }
}
