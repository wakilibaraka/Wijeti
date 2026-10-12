import AppKit
import Foundation
import Sparkle

/// Automatic updates through Sparkle.
///
/// Each release is published as a signed DMG plus an appcast entry. Sparkle checks the feed named
/// by `SUFeedURL` (one feed per CPU architecture, stamped in by `Scripts/build-app.sh`), verifies
/// the download against the EdDSA key in `SUPublicEDKey`, and offers to install it. A bare
/// executable (`swift run`) has no feed, so the updater simply stays off there.
@MainActor
public final class UpdateController: NSObject, ObservableObject {
    public static let shared = UpdateController()

    private let controller: SPUStandardUpdaterController
    public let isAvailable: Bool

    @Published public private(set) var canCheckForUpdates = false

    private override init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        isAvailable = !(configured ?? "").isEmpty
        controller = SPUStandardUpdaterController(
            startingUpdater: isAvailable,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    public var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    public var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }

    public func checkForUpdates() {
        guard isAvailable else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
