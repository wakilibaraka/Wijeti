import AppKit

/// UI verification that needs no Screen Recording permission.
///
/// `cacheDisplay(in:to:)` asks the view to draw *itself* into an offscreen bitmap, so the
/// pixels come from the view hierarchy rather than from the display server. That is the whole
/// trick behind both `--verify-presets` and `--capture-ui`: the app can prove what its own
/// windows look like without anything being granted first.
@MainActor
public enum WindowSnapshot {
    /// Renders a window's content view to an image, or `nil` when there is nothing to draw.
    ///
    /// The result is composited over an opaque background first. `cacheDisplay` only visits
    /// the content *view*, so anything the window itself would have painted — most noticeably
    /// the window background behind a grouped SwiftUI layout — comes back as transparent, and
    /// an artifact full of holes is not a faithful record of what the user sees.
    public static func capture(_ window: NSWindow?) -> NSImage? {
        guard let window, let contentView = window.contentView else { return nil }
        // Render the theme frame, not just the content view: the title bar, the traffic lights
        // and the toolbar are siblings of the content, and a picture of the design that omits
        // them is not a picture of the window. Falls back to the content view when there is no
        // frame (a borderless window).
        let view = contentView.superview ?? contentView
        // Bring the window's content up to date first. SwiftUI's hosted content keeps its last
        // rendered layer contents until something invalidates them, so a capture taken after a
        // resize could show pixels laid out for the previous size — a shifted or blank picture
        // that says nothing about what the window looks like now.
        if let host = contentView.subviews.first {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            host.displayIfNeeded()
        }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds)
        else {
            return nil
        }
        view.cacheDisplay(in: bounds, to: rep)
        let rendered = NSImage(size: bounds.size)
        rendered.addRepresentation(rep)
        return flattened(rendered, onto: background(of: window))
    }

    /// The colour to composite a capture over: the window's own background when it has one,
    /// and the standard window colour for a clear-background (vibrancy) window.
    private static func background(of window: NSWindow) -> NSColor {
        guard let color = window.backgroundColor, color.alphaComponent >= 0.05 else {
            return .windowBackgroundColor
        }
        return color
    }

    private static func flattened(_ image: NSImage, onto color: NSColor) -> NSImage {
        let rect = NSRect(origin: .zero, size: image.size)
        let output = NSImage(size: image.size)
        output.lockFocusFlipped(false)
        color.setFill()
        rect.fill()
        image.draw(in: rect)
        output.unlockFocus()
        return output
    }

    /// One-line description of a window's chrome, for verification runs.
    ///
    /// The redesign's window rules — close only, no minimize or zoom — are assertions about
    /// AppKit state, so they can be logged and checked instead of squinted at in a screenshot.
    /// `standardWindowButton` returns `nil` for a control the style mask does not create.
    public static func chromeSummary(of window: NSWindow?) -> String {
        guard let window else { return "no window" }
        // AppKit keeps the button objects around even when the style mask excludes them, so
        // the meaningful question is whether each one is hidden, not whether it exists.
        func describe(_ button: NSWindow.ButtonType) -> String {
            guard let button = window.standardWindowButton(button) else { return "absent" }
            return "\(button.isHidden ? "hidden" : "visible")/\(button.isEnabled ? "enabled" : "disabled")"
        }
        return [
            "styleMask=\(window.styleMask.rawValue)",
            "close=\(describe(.closeButton))",
            "miniaturize=\(describe(.miniaturizeButton))",
            "zoom=\(describe(.zoomButton))",
            "titlebarTransparent=\(window.titlebarAppearsTransparent)",
            "opaque=\(window.isOpaque)",
        ].joined(separator: " ")
    }

    /// Writes an image as PNG, logging either outcome. Returns whether the file landed.
    @discardableResult
    public static func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            NSLog("png encoding failed for %@", url.lastPathComponent)
            return false
        }
        do {
            try png.write(to: url)
            NSLog("wrote %@", url.logPath)
            return true
        } catch {
            NSLog("png write failed: %@", error.localizedDescription)
            return false
        }
    }
}
