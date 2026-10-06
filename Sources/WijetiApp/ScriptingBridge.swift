import AppKit
import Foundation
import WijetiCore
import WijetiMacOS

/// AppleScript support matching the original `Uebersicht.sdef`: `refresh`, `reload`,
/// `every widget`, and the widget properties `id`, `hidden`, `showOnMainScreen`,
/// `showOnAllScreens`, plus `name`/`version` on the application.
///
/// It is wired the way `UBAppDelegate`/`UBWidgetForScripting` were rather than by parsing
/// Apple events by hand: the sdef names real Cocoa classes and keys, AppKit does the event
/// plumbing, and the two command objects call back into `HostApp`.
///
/// The sdef requires **exactly eight-character command codes** — four- or five-character
/// ones make the whole dictionary report as "corrupted" (-2705), which is why the original
/// Übersicht used codes like `wigetrfs`.
final class ScriptingBridge {
    static let shared = ScriptingBridge()
    var host: HostApp?

    private init() {}
}

/// One widget, exposed to AppleScript. Properties are backed by the live widget server
/// state, so a script that sets `hidden` sees the widget disappear and the change persists
/// (the server owns `WidgetSettings.json`).
@objc(WijetiWidget)
final class WijetiWidget: NSObject {
    private let widgetID: String

    init(id: String) {
        self.widgetID = id
        super.init()
    }

    private var host: HostApp? { ScriptingBridge.shared.host }

    @objc var id: String { widgetID }

    @objc var hidden: Bool {
        get { host?.settings(for: widgetID).hidden ?? false }
        set { host?.updateSettings(widgetID) { $0.hidden = newValue } }
    }

    @objc var showOnMainScreen: Bool {
        get { host?.settings(for: widgetID).showOnMainScreen ?? false }
        set { host?.updateSettings(widgetID) { $0.showOnMainScreen = newValue } }
    }

    @objc var showOnAllScreens: Bool {
        get { host?.settings(for: widgetID).showOnAllScreens ?? WidgetSettings().showOnAllScreens }
        set { host?.updateSettings(widgetID) { $0.showOnAllScreens = newValue } }
    }

    override var description: String { "widget \"\(widgetID)\"" }

    // Backs <responds-to> in Wijeti.sdef, so `refresh widget 1` reaches this instance.
    @objc func refresh(_ sender: Any?) {
        host?.refreshWidgets(ids: [widgetID])
    }

    @objc func reload(_ sender: Any?) {
        host?.reloadWidgets()
    }
}

/// `refresh` — re-runs one widget's command, or every widget's.
@objc(WijetiRefreshCommand)
final class WijetiRefreshCommand: NSScriptCommand {
    // `NSScriptCommand.performDefaultImplementation` is declared `- (nullable id)`; the Swift
    // override must return `Any?` or the compiler cannot match the selector.
    override func performDefaultImplementation() -> Any? {
        guard let host = ScriptingBridge.shared.host else { return nil }
        if let target = directParameter as? WijetiWidget {
            host.refreshWidgets(ids: [target.id])
        } else if let id = directParameter as? String {
            host.refreshWidgets(ids: [id])
        } else {
            host.refreshWidgets()
        }
        return nil
    }
}

/// `reload` — re-reads the widget bundles from disk.
@objc(WijetiReloadCommand)
final class WijetiReloadCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptingBridge.shared.host?.reloadWidgets()
        return nil
    }
}

/// `count widgets`.
///
/// `count` is not part of AppleScript's language layer: the interpreter sends a Core Suite
/// `corecnte` Apple event to whatever `count` is applied to. Apps that declare the event in
/// their dictionary get Cocoa scripting's default implementation, which returns `missing
/// value`; declaring `<cocoa class="WijetiCountCommand"/>` is what makes the number come back.
@objc(WijetiCountCommand)
final class WijetiCountCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let host = ScriptingBridge.shared.host else { return 0 }

        // Cocoa evaluates the specifier for us, so the direct parameter is already the array
        // of widget objects; a single object means a one-element match.
        if let widgets = directParameter as? [Any] {
            return widgets.count
        }
        if directParameter == nil {
            return host.widgetIDs.count
        }
        return 1
    }
}
