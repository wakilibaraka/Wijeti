import AppKit
import SwiftUI
import WijetiCore

/// First-launch onboarding surface.
///
/// One screen: what Wijeti is, where widget management lives, and a way straight into the Widget
/// Library. Earlier versions walked through a three-step feature tour that then repeated
/// permission prompts and the launch-at-login switch — both of which also live in Settings — so
/// the tour delayed the actual task (browsing widgets) and gave nobody a way to see it again.
/// Setup that belongs to Settings stays in Settings; this window only has to hand the user the
/// library.
///
/// Once dismissed it is not shown again for that user (stored in `UserDefaults`), but
/// `show(force: true)` replays it on demand from Settings → General.
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let host: HostApp
    private let allowsCompletedOnboarding: Bool

    /// The key under which we store the fact that onboarding has been seen.
    public static let didCompleteKey = "OnboardingDidComplete"

    public init(host: HostApp, allowsCompletedOnboarding: Bool = false) {
        self.host = host
        self.allowsCompletedOnboarding = allowsCompletedOnboarding
        super.init()
    }

    /// Shows the window on first launch, or on demand when `force` is true (the replay path
    /// from Settings). `allowsCompletedOnboarding` is the `--capture-ui` escape hatch, which
    /// draws the window even though a real user has already dismissed it.
    @MainActor
    public func show(force: Bool = false) {
        guard force || allowsCompletedOnboarding || !UserDefaults.standard.bool(forKey: Self.didCompleteKey) else { return }

        if window == nil {
            let content = OnboardingView { [weak self] openLibrary in
                self?.dismiss(openLibrary: openLibrary)
            }
            // The window's size governs the layout, not the SwiftUI content's ideal size: the
            // tour must fill its window at any size rather than push it around.
            let hosting = FixedSizedHostingController(rootView: content)
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to Wijeti"
            // Standard resizable chrome, like every other window: no custom controls to learn
            // and macOS tiling, zoom and minimize keep working.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.isMovableByWindowBackground = false
            window.minSize = AppMetrics.onboardingMinimum
            window.setContentSize(NSSize(width: 640, height: 540))
            pinHostingViewToWindowContent(window)
            self.window = window
        }

        centerOnMainScreen()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Centers on the visible frame of the screen the window is (or will be) on, so the
    /// onboarding card sits in the middle of the user's display rather than wherever the
    /// compositor puts a new window.
    @MainActor
    private func centerOnMainScreen() {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrameTopLeftPoint(NSPoint(x: origin.x, y: origin.y + size.height))
    }

    /// Closing with the red button counts as finishing; otherwise the window would reappear on
    /// every launch. `windowShouldClose` fires only for a close the user asked for, not when the
    /// app quits underneath the open window.
    @MainActor
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        UserDefaults.standard.set(true, forKey: Self.didCompleteKey)
        return true
    }

    /// Renders the window for `--capture-ui`.
    @MainActor
    public func snapshotWindowImage() -> NSImage? {
        WindowSnapshot.capture(window)
    }

    /// `openLibrary` is false for "Maybe Later": the tour is optional, and dismissing it must not
    /// hijack the desktop with a window the user did not ask for.
    @MainActor
    private func dismiss(openLibrary: Bool) {
        UserDefaults.standard.set(true, forKey: Self.didCompleteKey)
        window?.performClose(nil)
        guard openLibrary else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            // Open the widgets library so the first-launch path ends where the user actually
            // picks widgets, not back on the desktop.
            self?.openLibraryAfterOnboarding()
        }
    }

    /// Best-effort open of the widgets library after onboarding dismiss.
    /// The app delegate owns the library window, so we ask the app to perform the same
    /// action the tray menu uses; if nothing is wired, this is a silent no-op.
    @MainActor
    private func openLibraryAfterOnboarding() {
        guard let app = NSApp else { return }
        if let delegate = app.delegate, delegate.responds(to: NSSelectorFromString("openLibrary")) {
            delegate.perform(NSSelectorFromString("openLibrary"))
            return
        }
    }
}

// MARK: - SwiftUI onboarding view

private struct OnboardingPoint: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String
}

private let onboardingPoints: [OnboardingPoint] = [
    OnboardingPoint(
        symbol: "square.grid.2x2",
        title: "Browse a live widget library",
        detail: "Preview every bundled widget and add it to your desktop in one click."
    ),
    OnboardingPoint(
        symbol: "menubar.rectangle",
        title: "Live in the menu bar",
        detail: "Wijeti stays out of the Dock. ⌘L opens the library, ⌘, opens Settings."
    ),
    OnboardingPoint(
        symbol: "lock.shield",
        title: "No system-wide install",
        detail: "Widgets run in a bundled server in their own process, and permissions are optional — you can review them in Settings → Permissions any time."
    ),
]

struct OnboardingView: View {
    /// Called with whether the library should open once the tour is dismissed.
    let onFinish: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: AppMetrics.paneGutter + 4) {
                    hero
                    VStack(spacing: 6) {
                        Text("Welcome to Wijeti")
                            .font(.largeTitle.weight(.bold))
                        Text("A home for useful, live widgets on your Mac desktop.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(onboardingPoints.enumerated()), id: \.element.id) { index, point in
                            pointRow(point)
                            if index < onboardingPoints.count - 1 {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                    .appCardSurface()
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, AppMetrics.windowGutter)
                .padding(.top, AppMetrics.windowGutter + 6)
                .padding(.bottom, AppMetrics.paneGutter)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        .background(AppColor.windowSurface)
    }

    /// The one branded moment in the app: a restrained accent gradient behind the app glyph.
    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AppGradient.brand)
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 42, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .frame(width: 104, height: 104)
        .accessibilityHidden(true)
    }

    private func pointRow(_ point: OnboardingPoint) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: point.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTone.accent.color)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(point.title)
                    .font(.callout.weight(.semibold))
                Text(point.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppMetrics.cardPadding)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 12) {
                Text("You can see this tour again from Settings → General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Maybe Later") { onFinish(false) }
                    .buttonStyle(.bordered)
                Button("Open Widget Library") { onFinish(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, AppMetrics.windowGutter)
            .padding(.vertical, 14)
        }
    }
}
