import AppKit
import SwiftUI
import WijetiCore

/// First-launch onboarding surface.
///
/// Designed as a native macOS window that borrows the iOS "Feature Highlights" lead style:
/// a compact app-title header, a vertical stack of feature cards each led by an SF Symbol,
/// bold headline weight on the title, `.secondary`-styled descriptions, and a flat
/// primary call-to-action pinned to the bottom with a press spring.
///
/// Once dismissed, it is never shown again for that user (stored in `UserDefaults`).
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let host: HostApp

    /// The key under which we store the fact that onboarding has been seen.
    public static let didCompleteKey = "OnboardingDidComplete"

    public init(host: HostApp) {
        self.host = host
        super.init()
    }

    @MainActor
    public func show() {
        // Only surface on first launch. After that this controller is a no-op.
        guard !UserDefaults.standard.bool(forKey: Self.didCompleteKey) else { return }

        if window == nil {
            let content = OnboardingView(host: host) { [weak self] in
                self?.dismiss()
            }
            let hosting = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to Wijeti"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.conditionalSetContentSize(width: 560, height: 560)
            window.isOpaque = false
            window.backgroundColor = NSColor.windowBackgroundColor
            window.titlebarAppearsTransparent = false
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        // The window's first responder order should include the CTA so Return/Enter
        // submits it. We prefer the button to be the key view on show.
        let theView = window?.contentViewController?.view
        if let button = theView?.descendantView(matching: { $0.isKind(of: NSButton.self) }) as? NSButton {
            window?.initialFirstResponder = button
        }
    }

    @MainActor
    private func dismiss() {
        UserDefaults.standard.set(true, forKey: Self.didCompleteKey)
        window?.performClose(nil)
    }
}

extension NSWindow {
    func conditionalSetContentSize(width: CGFloat, height: CGFloat) {
        if contentViewController?.preferredContentSize == .zero {
            setContentSize(NSSize(width: width, height: height))
        }
    }
}

extension NSView {
    func descendantView(
        matching predicate: (NSView) -> Bool,
        after view: NSView? = nil
    ) -> NSView? {
        let start = view ?? self
        if predicate(start) { return start }
        for sub in start.subviews {
            if let found = descendantView(matching: predicate, after: sub) {
                return found
            }
        }
        return nil
    }
}

// MARK: - SwiftUI onboarding view

/// Small view model so the CTA animation state lives on an ObservableObject rather than
/// as a local `@State` (the toolchain cannot resolve SwiftUI's `State` macro in this
/// AppKit/SwiftUI mix).
@MainActor
private final class OnboardingViewModel: ObservableObject {
    @Published var buttonPressed = false
}

struct OnboardingView: View {
    let host: HostApp
    let onDismiss: () -> Void
    @StateObject private var viewModel = OnboardingViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            featureList
            Divider()
            ctaFooter
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .frame(width: 560, height: 560)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)
                Text("Wijeti")
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)

            Text("Desktop widgets, on your terms.")
                .font(.title2.weight(.medium))
                .padding(.horizontal, 22)

            Text(
                "A native Swift host for desktop widgets on macOS — a modern menu bar, "
                + "a Widget Library without Finder, and a Settings panel built the way Apple "
                + "ships settings surfaces today."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .lineSpacing(4)
            .padding(.top, 8)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Feature list (iOS "Feature Highlights" lead style)

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow(
                symbol: "minimap",
                title: "Widget Library without Finder",
                body: "Browse bundled widgets by category, search, and install in one click. "
                    + "Drag a widget folder onto the window, or use Install Your Own… — you "
                    + "never need to know where widgets live on disk."
            )

            featureRow(
                symbol: "figure.walk",
                title: "Widgets that run on their own schedule",
                body: "Each widget has its own refresh rhythm. Wijeti hides in the menu bar so "
                    + "your desktop stays clear, and widgets can sit behind other apps when you "
                    + "want them out of the way."
            )

            featureRow(
                symbol: "lock.doc",
                title: "Permissions and data sources in one place",
                body: "Location, Full Disk Access, Automation, and Notifications — each one shown "
                    + "with its real status, and a direct link to the exact System Settings pane. "
                    + "Weather uses Open-Meteo, which needs no API key."
            )

            featureRow(
                symbol: "character.man.text.serve.held",
                title: "Scriptable from day one",
                body: "AppleScript speaks `refresh`, `reload`, `count widgets`, and `every widget` "
                    + "with `id`, `hidden`, and screen placement. Driving Wijeti from a script or "
                    + "another app works out of the box."
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private func featureRow(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - CTA footer (flat button pinned to bottom, press spring)

    private var ctaFooter: some View {
        HStack(spacing: 14) {
            Spacer()

            Button(action: {
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.75)) {
                    viewModel.buttonPressed = true
                }
                // Briefly depress, then dismiss after the spring settles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    onDismiss()
                }
            }) {
                Text("Get Started")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .blue.opacity(0.85)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .compositingGroup()
                    .shadow(color: .black.opacity(viewModel.buttonPressed ? 0.25 : 0.12), radius: viewModel.buttonPressed ? 6 : 3, x: 0, y: viewModel.buttonPressed ? 2 : 1)
            }
            .buttonStyle(.plain)
            .scaleEffect(viewModel.buttonPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: viewModel.buttonPressed)

            Button("I'll set it up later") {
                onDismiss()
            }
            .font(.subheadline.weight(.regular))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }
}
