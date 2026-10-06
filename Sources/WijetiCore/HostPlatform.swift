import Foundation

/// Everything the portable core needs from the machine it runs on.
///
/// A Linux host would implement this with X11 override-redirect windows or a Wayland
/// layer-shell surface; a Windows host with layered click-through windows. Neither would
/// touch `WijetiCore`.
public protocol HostPlatform: AnyObject {
    /// Directory holding `localnode` and `server.js` (the `server/release` output).
    var serverResourcesDirectory: URL { get }

    /// Where `WidgetSettings.json` lives — the `-s` argument of the server.
    var preferencesDirectory: URL { get }

    /// Where `.jsx` widgets live — the `-d` argument of the server.
    var widgetDirectory: URL { get }

    /// Bundled `.jsx` presets offered for installation from the tray menu.
    var presetsDirectory: URL { get }

    var initialServerPort: Int { get }

    func makeProcessLauncher() -> ServerProcessLaunching
    func openExternal(_ url: URL)
}
