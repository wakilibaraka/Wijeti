import AppKit

public enum DesktopWindowType {
    case background
    case foreground
}

/// A borderless, transparent, screen-filling window pinned to the desktop level.
///
/// Ported from `UBWindow`: it must never appear in Mission Control, must follow the user
/// across Spaces, and must be click-through by default — `detectWidgetHover.js` posts
/// `widgetEnter` / `widgetLeave` and only then is the window allowed to take mouse events.
public final class DesktopWindow: NSWindow {
    private var type: DesktopWindowType = .background
    private var acceptsMouseMoved: Bool = false

    public init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        isRestorable = false
        displaysWhenScreenProfileChanges = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        apply(type: .background)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DesktopWindow is not available from a coder")
    }

    public func apply(type newType: DesktopWindowType) {
        type = newType
        switch newType {
        case .foreground:
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        case .background:
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        }
        ignoresMouseEvents = newType == .background
        acceptsMouseMoved = newType == .foreground
    }

    public override var canBecomeKey: Bool { type == .foreground }
    public override var canBecomeMain: Bool { type == .foreground }
    public override var acceptsFirstResponder: Bool { type == .foreground }

    public override var acceptsMouseMovedEvents: Bool {
        get { acceptsMouseMoved }
        set { acceptsMouseMoved = newValue }
    }
}
