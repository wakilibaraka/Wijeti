import AppKit
import SwiftUI

/// Bridges `NSVisualEffectView` into SwiftUI.
///
/// SwiftUI's `Material` is composited from whatever is behind it *inside* the window, which
/// gives a flat, baked-in look. A sidebar is supposed to sample the desktop wallpaper and the
/// windows behind this one, and that only happens with `blendingMode = .behindWindow` on a
/// real `NSVisualEffectView`. This is the smallest way to get that without replacing the
/// window's content with a hand-built AppKit view hierarchy.
///
/// For the blend to have anything to sample, the host window must not be opaque — see
/// `WidgetLibraryWindow`, which clears the window background and lets the content and detail
/// panes paint their own.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // `.followsWindowActiveState` is what makes the sidebar recede when the window is in
        // the background, the way every other macOS source list does.
        view.state = .followsWindowActiveState
        view.isEmphasized = isEmphasized
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = isEmphasized
    }
}
