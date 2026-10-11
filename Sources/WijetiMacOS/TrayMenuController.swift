import AppKit

/// The menu-bar item, ported from `-[UBAppDelegate addStatusItemToMenu:]` plus the
/// `showPreferences: / openWidgetDir: / visitWidgetGallery: / refreshWidgets:` actions.
public final class TrayMenuController {
    private let host: HostApp
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var activeWidgetsMenuItem: NSMenuItem?
    private var activeWidgetsSubmenu: NSMenu?

    public var onShowPreferences: (() -> Void)?
    public var onOpenLibrary: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init(host: HostApp) {
        self.host = host
    }

    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.makeIcon()
        item.button?.toolTip = "Wijeti — open the menu for widgets, preferences, and quit."
        statusItem = item

        let menu = NSMenu()
        let library = makeMenuItem("Widget Library…", #selector(openLibrary))
        library.keyEquivalent = "l"
        menu.addItem(library)
        let refreshAll = makeMenuItem("Refresh All Widgets", #selector(refreshAll))
        refreshAll.keyEquivalent = "r"
        menu.addItem(refreshAll)
        let reloadWidgets = makeMenuItem("Reload Widgets", #selector(reloadWidgets))
        menu.addItem(reloadWidgets)
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Open Widgets Folder", #selector(openWidgetFolder)))
        menu.addItem(makeMenuItem("Visit Widget Gallery", #selector(visitGallery)))
        menu.addItem(.separator())

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        // Active widgets submenu
        let activeWidgets = NSMenuItem(title: "Active Widgets", action: nil, keyEquivalent: "")
        activeWidgets.isEnabled = false
        activeWidgetsSubmenu = NSMenu()
        activeWidgets.submenu = activeWidgetsSubmenu
        menu.addItem(activeWidgets)
        refreshActiveWidgets()

        menu.addItem(.separator())
        // Deliberately no key equivalents: the status menu is only open after a click, so
        // they would fire nowhere useful, and Cmd-A / Cmd-H belong to Select All and Hide.
        // The real shortcuts live in the app's main menu.
        menu.addItem(makeMenuItem("Show All Widgets", #selector(showAllWidgets)))
        menu.addItem(makeMenuItem("Hide All Widgets", #selector(hideAllWidgets)))
        menu.addItem(.separator())
        let preferences = makeMenuItem("Preferences…", #selector(showPreferences))
        preferences.keyEquivalent = ","
        menu.addItem(preferences)
        menu.addItem(.separator())
        let quit = makeMenuItem("Quit Wijeti", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)

        item.menu = menu
        NSLog(
            "tray installed: %d menu item(s) [%@]",
            menu.numberOfItems,
            menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", ")
        )
        host.onStatus = { [weak self] message in
            self?.statusMenuItem?.title = message
        }
        // `host.onStateChange` is deliberately NOT set here. It is a single callback, so
        // claiming it from the menu would silently displace whoever set it first — which is
        // the app delegate, whose handler owns the first-state behaviour (opening a window
        // once widgets are known) and the `--snapshot-dir` proof. The delegate calls
        // `refreshStatus()` from its own handler instead, so both run.
    }

    public func refreshStatus() {
        statusMenuItem?.title = host.port.map { "Running on port \($0)" } ?? "Server not running"
        refreshActiveWidgets()
    }

    private func refreshActiveWidgets() {
        guard let submenu = activeWidgetsSubmenu else { return }
        // Remove old widget items (keep the title item)
        let itemsToRemove = submenu.items.filter { $0.action == #selector(toggleWidget(_:)) }
        for item in itemsToRemove {
            submenu.removeItem(item)
        }

        let visibleWidgets = host.widgetIDs.filter { id in
            let settings = host.settings(for: id)
            return !settings.hidden
        }

        if visibleWidgets.isEmpty {
            let empty = NSMenuItem(title: "No active widgets", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for id in visibleWidgets {
                let item = NSMenuItem(title: id, action: #selector(toggleWidget(_:)), keyEquivalent: "")
                item.target = self
                item.state = .on
                submenu.addItem(item)
            }
        }
    }

    @objc private func toggleWidget(_ sender: NSMenuItem) {
        // Toggle visibility of the widget whose id matches the menu item title
        let widgetID = sender.title
        let currentSettings = host.settings(for: widgetID)
        host.updateSettings(widgetID) { $0.hidden = !currentSettings.hidden }
        // Flip the menu item state
        sender.state = sender.state == .on ? .off : .on
    }

    @objc private func refreshAll() { host.refreshWidgets() }
    @objc private func reloadWidgets() { host.reloadWidgets() }
    @objc private func openWidgetFolder() { host.revealWidgetDirectory() }
    @objc private func openLibrary() { onOpenLibrary?() }
    @objc private func visitGallery() { host.visitGallery() }
    @objc private func showPreferences() { onShowPreferences?() }
    @objc private func showAllWidgets() {
        // No confirmation — this is an explicit power action the user invoked.
        host.enableAllVisibleNow()
        onOpenLibrary?()
    }
    @objc private func hideAllWidgets() {
        host.disableAllNow()
        onOpenLibrary?()
    }
    @objc private func quit() { onQuit?() }

    private func makeMenuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    /// Draws the menu-bar glyph so the app carries no image assets of its own.
    private static func makeIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setStroke()
        let rect = NSRect(x: 2.5, y: 2.5, width: 13, height: 13)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.lineWidth = 1.6
        path.stroke()
        path.move(to: NSPoint(x: 6, y: 10))
        path.line(to: NSPoint(x: 12, y: 10))
        path.move(to: NSPoint(x: 6, y: 7.5))
        path.line(to: NSPoint(x: 12, y: 7.5))
        path.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
