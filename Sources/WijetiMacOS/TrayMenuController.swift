import AppKit

/// The menu-bar item, ported from `-[UBAppDelegate addStatusItemToMenu:]` plus the
/// `showPreferences: / openWidgetDir: / visitWidgetGallery: / refreshWidgets:` actions.
public final class TrayMenuController: NSObject, NSMenuDelegate {
    private let host: HostApp
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var activeWidgetsMenuItem: NSMenuItem?
    private var activeWidgetsSubmenu: NSMenu?
    private var messageMenuItem: NSMenuItem?
    private var messageClearWork: DispatchWorkItem?
    private var isMenuOpen = false
    /// The (id, hidden) list the submenu was last built from; rebuilt only when it changes.
    private var renderedWidgets: [String] = []

    public var onShowPreferences: (() -> Void)?
    public var onOpenLibrary: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init(host: HostApp) {
        self.host = host
        super.init()
    }

    /// Server health shown at the top of the menu and as a dot on the status-item icon.
    private enum Health {
        case active(Int)
        case reloading
        case stopped

        var label: String {
            switch self {
            case .active(let port): return "Active — port \(port)"
            case .reloading: return "Reloading…"
            case .stopped: return "Stopped"
            }
        }

        var color: NSColor {
            switch self {
            case .active: return .systemGreen
            case .reloading: return .systemOrange
            case .stopped: return .systemRed
            }
        }
    }

    private var health: Health {
        if let port = host.port { return .active(port) }
        if host.supervisor.gaveUp { return .stopped }
        if host.supervisor.isRunning || host.supervisor.restartScheduled { return .reloading }
        return .stopped
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
        // `HostApp.installPresets()` was previously reachable only from the `--install-presets`
        // launch flag, so the feature existed but no user could find it.
        menu.addItem(makeMenuItem("Install Bundled Widgets", #selector(installBundledWidgets)))
        menu.addItem(makeMenuItem("Visit Widget Gallery", #selector(visitGallery)))
        menu.addItem(.separator())

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status
        let message = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        message.isEnabled = false
        message.isHidden = true
        menu.addItem(message)
        messageMenuItem = message

        // Active widgets submenu
        let activeWidgets = NSMenuItem(title: "Active Widgets", action: nil, keyEquivalent: "")
        activeWidgetsSubmenu = NSMenu()
        activeWidgets.submenu = activeWidgetsSubmenu
        menu.addItem(activeWidgets)
        activeWidgetsMenuItem = activeWidgets

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

        menu.delegate = self
        item.menu = menu
        refreshStatus()
        NSLog(
            "tray installed: %d menu item(s) [%@]",
            menu.numberOfItems,
            menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", ")
        )
        host.onStatus = { [weak self] message in
            self?.showTransient(message)
        }
        // `host.onStateChange` is deliberately NOT set here. It is a single callback, so
        // claiming it from the menu would silently displace whoever set it first — which is
        // the app delegate, whose handler owns the first-state behaviour (opening a window
        // once widgets are known) and the `--snapshot-dir` proof. The delegate calls
        // `refreshStatus()` from its own handler instead, so both run.
    }

    /// Draws attention to the menu-bar icon on first launch.
    ///
    /// There is no API to animate or point at a status item, so this dims and restores the
    /// glyph a few times — the one affordance available. Deliberately brief: a menu bar icon
    /// that kept blinking would be worse than the problem it solves.
    public func pulseIcon(times: Int = 3) {
        guard let button = statusItem?.button else { return }
        let step: TimeInterval = 0.35
        for index in 0..<(times * 2) {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(index)) {
                button.appearsDisabled = index % 2 == 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(times * 2)) {
            button.appearsDisabled = false
        }
    }

    public func refreshStatus() {
        let health = self.health
        let line = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: health.color]
        )
        line.append(NSAttributedString(string: health.label))
        statusMenuItem?.attributedTitle = line
        statusItem?.button?.toolTip = "Wijeti — \(health.label)"
        refreshActiveWidgets()
    }

    /// Shows a short-lived message under the health line, then clears it. Kept apart from the
    /// health line so the 1 Hz refresh cannot wipe it within a second.
    private func showTransient(_ message: String) {
        messageMenuItem?.title = message
        messageMenuItem?.isHidden = false
        messageClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.messageMenuItem?.isHidden = true
        }
        messageClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    public func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        refreshStatus()
    }

    public func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    /// Lists every installed widget with a check for the visible ones, so a hidden widget can
    /// be shown again from here. Rebuilt only when the list changes and never while the menu
    /// is open (replacing items under the cursor makes the menu flicker and drops clicks).
    private func refreshActiveWidgets() {
        guard let submenu = activeWidgetsSubmenu, !isMenuOpen else { return }
        let ids = host.widgetIDs
        let signature = ids.map { "\($0):\(host.settings(for: $0).hidden)" }
        guard signature != renderedWidgets else { return }
        renderedWidgets = signature

        submenu.removeAllItems()
        if ids.isEmpty {
            let empty = NSMenuItem(title: "No widgets installed", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }
        for id in ids {
            let item = NSMenuItem(title: Self.displayName(for: id), action: #selector(toggleWidget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = host.settings(for: id).hidden ? .off : .on
            submenu.addItem(item)
        }
    }

    /// `liquid-glass-calendar-widget-index-jsx` → `liquid glass calendar`.
    static func displayName(for id: String) -> String {
        var name = id
        for suffix in ["-index-jsx", "-index-js", "-index-coffee", "-jsx", "-js", "-coffee"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        if name.hasSuffix("-widget") { name = String(name.dropLast("-widget".count)) }
        return name.replacingOccurrences(of: "-", with: " ")
    }

    @objc private func toggleWidget(_ sender: NSMenuItem) {
        // Toggle visibility of the widget whose id matches the menu item title
        guard let widgetID = sender.representedObject as? String else { return }
        let currentSettings = host.settings(for: widgetID)
        host.updateSettings(widgetID) { $0.hidden = !currentSettings.hidden }
        sender.state = sender.state == .on ? .off : .on
        renderedWidgets = []
    }

    @objc private func refreshAll() { host.refreshWidgets() }
    @objc private func reloadWidgets() { host.reloadWidgets() }
    @objc private func openWidgetFolder() { host.revealWidgetDirectory() }
    @objc private func installBundledWidgets() { host.installPresets() }
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
