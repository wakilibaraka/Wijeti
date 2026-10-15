import AppKit
import SwiftUI
import WijetiCore

// MARK: - Design tokens
//
// One small vocabulary shared by the Widget Library, Settings, onboarding, and the menu-bar
// surfaces. Values are deliberately few: system surfaces, one accent, three status tones and a
// neutral for everything that is merely structural. Everything is expressed as a semantic
// AppKit colour, so light/dark appearance, increased contrast and accent-colour changes are
// handled by the system rather than re-implemented here.

/// Shared spacing, radii and window minimums.
public enum AppMetrics {
    /// Outer margin of a window's content.
    public static let windowGutter: CGFloat = 20
    /// Margin between panes and between a pane's content and its heading.
    public static let paneGutter: CGFloat = 16
    /// Vertical rhythm between stacked sections.
    public static let sectionSpacing: CGFloat = 12
    /// Inside a card: heading padding and gap between rows.
    public static let cardPadding: CGFloat = 14
    public static let cardRadius: CGFloat = 12
    public static let smallRadius: CGFloat = 9


    /// Window minimums: small enough that a half-screen tile on a 1280-wide display still
    /// works, since every window keeps standard resizable chrome.
    public static let libraryMinimum = NSSize(width: 780, height: 520)
    public static let settingsMinimum = NSSize(width: 660, height: 480)
    public static let onboardingMinimum = NSSize(width: 560, height: 460)

    /// Below this library width the browser and the preview/management pane stop sharing the
    /// row and the pane takes over the content area instead.
    public static let librarySideBySideMinimum: CGFloat = 1000
}

/// The semantic role of a badge or tinted label. A single accent plus three status tones keeps
/// colour meaningful instead of decorative.
enum AppTone {
    case neutral
    case accent
    case positive
    case warning
    case negative

    var color: Color {
        switch self {
        case .neutral: return Color(nsColor: .secondaryLabelColor)
        case .accent: return Color.accentColor
        case .positive: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemOrange)
        case .negative: return Color(nsColor: .systemRed)
        }
    }

    /// Tinted fill behind a badge of this tone. Low enough to read as a tint in both
    /// appearances rather than as a colour block.
    var fill: Color { color.opacity(0.14) }
}

/// Semantic surfaces and strokes.
enum AppColor {
    /// A card or grouped section sitting on the window background.
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// The window's own background.
    static let windowSurface = Color(nsColor: .windowBackgroundColor)
    /// A surface for content that should recede (preview placeholders, empty states).
    static let recessedSurface = Color(nsColor: .underPageBackgroundColor)
    /// Hairline around a card. Uses the label colour so it tracks appearance and contrast.
    static let border = Color.primary.opacity(0.09)
    /// A slightly stronger stroke for the selected item.
    static let selectedBorder = Color.accentColor.opacity(0.85)
    /// A neutral chip/badge fill.
    static let chipFill = Color.secondary.opacity(0.12)
}

/// Restrained gradients, used only for branded moments (the onboarding hero). Never behind
/// functional controls or as a window wallpaper.
enum AppGradient {
    static var brand: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.55)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Window content hosting

/// Pins SwiftUI's hosting view to its window's content view.
///
/// `NSHostingController`'s navigation-split host reports a fixed intrinsic height (measured at
/// 787pt here, whatever the window size) and AppKit then centres it inside the content view.
/// Every window shorter than that had the top of its layout pushed above the window — the pane
/// heading and the sidebar search field ended up out of sight behind the toolbar, and making the
/// window shorter only increased the offset. Constraining the host to the content view leaves the
/// window's own size as the only thing that decides the layout.
///
/// Call this once, after the window's initial content size has been set.
@MainActor
public func pinHostingViewToWindowContent(_ window: NSWindow) {
    guard let content = window.contentView, let host = content.subviews.first else { return }
    // Frame-based rather than constraint-based on purpose: activating constraints on SwiftUI's
    // platform-view host trips an AppKit assertion inside the hosting view.
    host.autoresizingMask = [.width, .height]
    host.frame = content.bounds
}

/// An `NSHostingController` that keeps its platform host the size of the window.
///
/// Re-applied in `viewDidLayout`, not just once at setup: SwiftUI re-imposes its own height on
/// the host during a resize (measured at 787pt regardless of window size), and re-pinning before
/// the layout pass only meant SwiftUI overwrote it a moment later.
public final class FixedSizedHostingController<Content: View>: NSHostingController<Content> {
    public override var preferredContentSize: NSSize {
        get { super.preferredContentSize }
        set {} // The window's own size decides; SwiftUI must not resize its host.
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard let host = view.subviews.first else { return }
        if host.frame != view.bounds {
            host.frame = view.bounds
        }
    }
}

// MARK: - Shared surfaces

extension View {
    /// Paints the standard card: system surface, hairline border, consistent radius.
    func appCardSurface(
        radius: CGFloat = AppMetrics.cardRadius,
        fill: Color = AppColor.surface,
        border: Color = AppColor.border
    ) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(border, lineWidth: 1)
            }
    }
}

/// A small status or category pill. Replaces per-pane hand-tinted badges so every surface
/// speaks the same colour language.
struct AppStatusBadge: View {
    let text: String
    var tone: AppTone = .neutral
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tone.fill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A flat category/source chip. Neutral by design: categories are structure, not status.
struct AppChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(AppColor.chipFill))
            .accessibilityLabel(text)
    }
}

/// A status pill for a permission row: `Granted`, `Not Determined`, `Denied`, or `Check in Settings`.
struct PermissionBadge: View {
    let status: PermissionStatus

    private var tone: AppTone {
        switch status {
        case .granted: return .positive
        case .denied: return .negative
        case .notDetermined: return .warning
        case .unknown: return .neutral
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
        AppStatusBadge(text: status.label, tone: tone, symbol: symbol)
            .accessibilityLabel("Status: \(status.label)")
    }
}

// MARK: - Search field

/// A native `NSSearchField`, so the sidebar's search behaves and renders like the one in System
/// Settings: focus ring, clear button, and the system's own metrics.
struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search"

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func changed(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

// MARK: - Appearance of a pane heading

/// The standard look of a pane's heading block: title, one-line summary, and the shared
/// spacing every pane uses. Keeps the Settings panes and the Library header on one rhythm.
struct AppPaneHeading: View {
    let title: String
    var subtitle: String?
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
