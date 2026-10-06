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

    private func apply(port: Int) {
        let screens = NSScreen.screens
        var wanted: [String: WidgetWindow] = [:]

        for (index, screen) in screens.enumerated() {
            let screenID = index + 1
            for layer in WidgetLayer.allCases {
                let key = "\(screenID)-\(layer.rawValue)"
                let entry: WidgetWindow
                if let existing = windows[key] {
                    existing.window.setFrame(screen.frame, display: true)
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
                }
                entry.window.orderFrontRegardless()
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
        apply(port: lastPort)
        for entry in windows.values {
            entry.controller.forceRedraw()
        }
    }

    public func reloadAll() {
        for entry in windows.values {
            entry.controller.reload()
        }
    }

    public func shutdown() {
        for entry in windows.values {
            entry.window.orderOut(nil)
            entry.window.close()
        }
        windows.removeAll()
    }
}
