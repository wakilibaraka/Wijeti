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
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            self.window = window
        }

        centerOnMainScreen()
        NSApp.activate(ignoringOtherApps: true)
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
            x: 0, y: 0, width: 600, height: 580
        )).size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrameTopLeftPoint(NSPoint(x: origin.x, y: origin.y + size.height))
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
    /// 0-based step index. Steps are: welcome, library, permissions, done.
    @Published var step = 0
    let stepCount = 4

    var isFirst: Bool { step == 0 }
    var isLast: Bool { step == stepCount - 1 }
    /// The permissions step sits after the plain steps, before "done".
    var isPermissions: Bool { step == stepsBeforePermissions }
    /// Number of colourful steps shown before the permissions step.
    var stepsBeforePermissions: Int { 3 }

    func advance() {
        step = min(step + 1, stepCount - 1)
    }

    func back() {
        step = max(step - 1, 0)
    }
}

/// One step of the onboarding flow: symbol, tint, headline, and body copy.
private struct OnboardingStep: Identifiable {
    let id: Int
    let symbol: String
    let tint: Color
    let title: String
    let body: String
}

/// The permissions step differs from the plain steps: it lists permissions with live
/// status and a settings shortcut, plus the data sources note.
private struct OnboardingPermissionsView: View {
    @StateObject private var probe = PermissionProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wijeti itself needs almost nothing. These are for the widgets you add — "
                 + "macOS only prompts once per app, and a few are granted in System Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(Permission.Kind.all.enumerated()), id: \.element) { index, kind in
                    permissionRow(kind)
                    if index < Permission.Kind.all.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
        }
        .onAppear { probe.refresh() }
    }

    private func permissionRow(_ kind: Permission.Kind) -> some View {
        let granted = probe.statuses[kind] ?? false
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .font(.callout)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.callout.weight(.medium))
                Text(kind.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(kind.isProbeable ? "Request" : "Open Settings") {
                probe.request(kind)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { probe.refresh() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct OnboardingView: View {
    let host: HostApp
    let onDismiss: () -> Void
    @StateObject private var viewModel = OnboardingViewModel()
    /// Asked for here as well as in Settings: onboarding is the one moment the user is actually
    /// thinking about setup, and "launch at login" is the difference between the widgets being
    /// there tomorrow and not.
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var needsLoginItemApproval = false

    private var steps: [OnboardingStep] {

        [
            OnboardingStep(
                id: 0,
                symbol: "sparkles",
                tint: Color(red: 0.35, green: 0.45, blue: 0.95),
                title: "Welcome to Wijeti",
                body: "Desktop widgets on macOS, the modern way. Wijeti lives in your menu bar, "
                    + "runs widgets on their own schedule, and keeps the rest of your desktop clear."
            ),
            OnboardingStep(
                id: 1,
                symbol: "square.grid.2x2",
                tint: Color(red: 0.95, green: 0.55, blue: 0.25),
                title: "A library, not a folder",
                body: "Browse the bundled widget library by category and search, then install with "
                    + "one click. Want your own? Drop a widget folder or a .zip onto the window — "
                    + "or use Install Your Own… — and never touch Finder to wire one up."
            ),
            OnboardingStep(
                id: 2,
                symbol: "slider.horizontal.3",
                tint: Color(red: 0.30, green: 0.75, blue: 0.45),
                title: "Make it yours",
                body: "Toggle each widget on or off, choose whether it sits behind other apps or "
                    + "shows on every screen, preview it live, and remove it just as easily as it "
                    + "arrived. Everything is a single click away, with no hidden state."
            ),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isPermissions {
                permissionsStep
            } else if let step = currentStep {
                stepHeader(step)
            }

            Divider()
            footer
        }
        .frame(width: 600, height: 580)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    /// The current colorful step, or nil on the permissions step (which is a different
    /// layout entirely).
    private var currentStep: OnboardingStep? {
        guard viewModel.step < steps.count else { return nil }
        return steps[viewModel.step]
    }

    private func stepHeader(_ step: OnboardingStep) -> some View {
        VStack(alignment: .center, spacing: 12) {
            // Colourful rounded "app icon" tile.
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [step.tint, step.tint.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 76, height: 76)
                .overlay(
                    Image(systemName: step.symbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                )
                .shadow(color: step.tint.opacity(0.35), radius: 10, y: 4)

            Text(step.title)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)

            Text(step.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 26)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .transition(.opacity)
    }

    private var permissionsStep: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.90, green: 0.35, blue: 0.38),
                                     Color(red: 0.85, green: 0.30, blue: 0.60)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 76, height: 76)
                    .overlay(
                        Image(systemName: "lock.shield")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: Color(red: 0.85, green: 0.30, blue: 0.60).opacity(0.35), radius: 10, y: 4)
                    .padding(.top, 22)

                Text("Permissions & data sources")
                    .font(.system(.title2, design: .rounded).weight(.bold))

                OnboardingPermissionsView()
                    .padding(.horizontal, 22)

                loginItemCard
                    .padding(.horizontal, 22)
            }
            .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity)
    }

    /// The login item, plus the one sentence that tells a new user where the app actually lives
    /// once this window is closed.
    private var loginItemCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run in the background")
                .font(.callout.weight(.medium))

            Toggle("Launch Wijeti at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, wanted in
                    let achieved = LoginItem.setEnabled(wanted)
                    if wanted && !achieved {
                        // macOS parks this for manual approval; say so rather than letting the
                        // switch appear to do nothing.
                        needsLoginItemApproval = true
                    }
                    if achieved != wanted {
                        launchAtLogin = achieved
                    }
                }

            if needsLoginItemApproval && !launchAtLogin {
                Text("Approve Wijeti in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Wijeti keeps out of the Dock either way — the menu bar icon is where it lives, "
                 + "and the pulsing icon in your menu bar is it saying hello.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var footer: some View {
        HStack(spacing: 14) {
            // Step dots on the left.
            HStack(spacing: 6) {
                ForEach(0..<viewModel.stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == viewModel.step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                        .animation(.easeInOut(duration: 0.18), value: viewModel.step)
                }
            }

            Spacer()

            Button("Back") {
                withAnimation(.easeInOut(duration: 0.2)) { viewModel.back() }
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.bordered)
            .disabled(viewModel.isFirst)
            .opacity(viewModel.isFirst ? 0.4 : 1)

            if viewModel.isPermissions {
                Button("Finish — Open Library") {
                    onDismiss()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Button(viewModel.isFirst ? "Get Started" : "Next") {
                    withAnimation(.easeInOut(duration: 0.2)) { viewModel.advance() }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}
