import AppKit
import SwiftUI
import WijetiCore

/// First-launch onboarding surface.
///
/// A stepped, card-style introduction: each page pairs a colourful symbol card with a
/// title and short body, a step-dots indicator tracks progress, and the final step
/// covers permissions/data sources before dismissing into the Widget Library.
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
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
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
        let size = window.frameRect(forContentRect: NSRect(
            x: 0, y: 0, width: 640, height: 600
        )).size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrameTopLeftPoint(NSPoint(x: origin.x, y: origin.y + size.height))
    }

    /// Closing with the red button counts as finishing; otherwise the wizard would reappear on
    /// every launch. `windowShouldClose` fires only for a close the user asked for, not when the
    /// app quits underneath the open wizard.
    @MainActor
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        UserDefaults.standard.set(true, forKey: Self.didCompleteKey)
        return true
    }

    /// Renders the wizard for `--capture-ui`; `step` picks which page (0 welcome, 1 features, 2 permissions).
    @MainActor
    public func snapshotWindowImage() -> NSImage? {
        WindowSnapshot.capture(window)
    }

    @MainActor
    private func dismiss() {
        UserDefaults.standard.set(true, forKey: Self.didCompleteKey)
        window?.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            // Open the widgets library automatically so the first-launch path ends on the
            // place where the user actually picks widgets, not back on the desktop.
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

@MainActor
private final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, features, permissions }

    @Published var step: Step = .welcome

    var isFirst: Bool { step == .welcome }
    var isLast: Bool { step == .permissions }

    func advance() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }
}

private struct FeatureCard: Identifiable {
    let id = UUID()
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
}

private let featureCards: [FeatureCard] = [
    FeatureCard(symbol: "square.grid.2x2.fill", tint: .orange, title: "Widget Library",
                detail: "Browse bundled widgets, preview them live, install in one click. Drop in your own folder, .jsx or .zip."),
    FeatureCard(symbol: "cloud.sun.fill", tint: .cyan, title: "Weather without keys",
                detail: "Open-Meteo powers the weather widgets: no account, no API key, no signup."),
    FeatureCard(symbol: "menubar.rectangle", tint: .indigo, title: "Menu bar control",
                detail: "Show, hide and refresh widgets from the tray. ⌘L opens the library, ⌘, opens Settings."),
    FeatureCard(symbol: "lock.shield.fill", tint: .green, title: "Runs in its own process",
                detail: "Widgets run in a separate bundled server and web views. Nothing is installed system-wide."),
]

/// A status pill: `Granted`, `Not Determined`, `Denied`, or `Check in Settings`.
struct PermissionBadge: View {
    let status: PermissionStatus

    private var color: Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        case .unknown: return .secondary
        }
    }

    private var symbol: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        case .unknown: return "gearshape.fill"
        }
    }

    var body: some View {
        Label(status.label, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .accessibilityLabel("Status: \(status.label)")
    }
}

private struct OnboardingPermissionsView: View {
    @StateObject private var probe = PermissionProbe()

    private var kinds: [Permission.Kind] {
        [.location, .notifications, .accessibility, .automation]
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                row(kind)
                if index < kinds.count - 1 { Divider().padding(.leading, 14) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        .onAppear { probe.refresh() }
    }

    private func row(_ kind: Permission.Kind) -> some View {
        let status = probe.status(for: kind)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.callout.weight(.semibold))
                Text(kind.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PermissionBadge(status: status)
            Button(status == .notDetermined ? "Allow" : "Open Settings") {
                probe.request(kind)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct OnboardingView: View {
    let host: HostApp
    let onDismiss: () -> Void
    @StateObject private var viewModel = OnboardingViewModel()
    /// Asked for here as well as in Settings: "launch at login" is the difference between the
    /// widgets being there tomorrow and not.
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var needsLoginItemApproval = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch viewModel.step {
                case .welcome: welcome
                case .features: features
                case .permissions: permissions
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)

            footer
        }
        .frame(width: 640, height: 600)
        .background(.regularMaterial)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Welcome to Wijeti")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Beautiful desktop widgets for your Mac, written in plain HTML and JavaScript. "
                 + "Install one from the library and it appears on your desktop. There's nothing to configure first.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 460)
        }
        .padding(.top, 56)
    }

    private var features: some View {
        VStack(spacing: 20) {
            Text("What you get")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .padding(.top, 44)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(featureCards) { card in
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: card.symbol)
                            .font(.title2)
                            .foregroundStyle(card.tint)
                        Text(card.title).font(.headline)
                        Text(card.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.background.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 0)
        }
    }

    private var permissions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("A few optional permissions")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Wijeti itself needs almost nothing. These are for widgets that use them, "
                     + "and you can change any of them later in System Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                OnboardingPermissionsView()
                loginItemCard
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 12)
        }
    }

    private var loginItemCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch Wijeti at login", isOn: $launchAtLogin)
                .font(.callout.weight(.semibold))
                .onChange(of: launchAtLogin) { _, wanted in
                    let achieved = LoginItem.setEnabled(wanted)
                    if wanted && !achieved { needsLoginItemApproval = true }
                    if achieved != wanted { launchAtLogin = achieved }
                }
            if needsLoginItemApproval && !launchAtLogin {
                Text("Approve Wijeti in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Wijeti stays out of the Dock. Its menu bar icon is where it lives.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: Pinned footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(OnboardingViewModel.Step.allCases, id: \.rawValue) { step in
                        Circle()
                            .fill(step == viewModel.step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)

                Spacer()

                if !viewModel.isFirst {
                    Button("Back") { withAnimation(.easeInOut(duration: 0.2)) { viewModel.back() } }
                        .controlSize(.large)
                }

                if viewModel.isLast {
                    Button("Get Started") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { withAnimation(.easeInOut(duration: 0.2)) { viewModel.advance() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }
}
