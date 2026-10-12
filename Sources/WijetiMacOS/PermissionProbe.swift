import AppKit
import ApplicationServices
import AVFoundation
import CoreBluetooth
import CoreLocation
import Contacts
import EventKit
import Photos
import Speech
import UserNotifications
import WijetiCore

/// How a permission currently stands, as far as macOS lets us tell without prompting.
public enum PermissionStatus: Equatable, Sendable {
    case granted, notDetermined, denied
    /// Cannot be read without side effects (Local Network, Files & Folders, an app that is not running).
    case unknown

    public var label: String {
        switch self {
        case .granted: return "Granted"
        case .notDetermined: return "Not Determined"
        case .denied: return "Denied"
        case .unknown: return "Check in Settings"
        }
    }
}

/// Reads live status for every entry in `PermissionCatalog` and triggers the matching prompt.
///
/// The catalog says *what* exists; this says *how to ask macOS about it*. A permission with no
/// handler here falls back to `.unknown` and "Open Settings", so adding a catalog entry is never
/// a crash, only a less helpful row.
///
/// Refreshes itself whenever the app becomes active, which is how a change made in System
/// Settings shows up as soon as the user switches back.
@MainActor
public final class PermissionProbe: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public private(set) var states: [String: PermissionStatus] = [:]

    private let locationManager = CLLocationManager()
    private var bluetooth: CBCentralManager?
    private var activeObserver: NSObjectProtocol?

    public override init() {
        super.init()
        locationManager.delegate = self
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    public func status(for spec: PermissionSpec) -> PermissionStatus {
        states[spec.id] ?? .unknown
    }

    public func refresh() {
        for spec in PermissionCatalog.all {
            probe(spec) { [weak self] status in
                Task { @MainActor in self?.states[spec.id] = status }
            }
        }
    }

    // MARK: - Probing

    private func probe(_ spec: PermissionSpec, _ done: @escaping @Sendable (PermissionStatus) -> Void) {
        if let target = spec.automationTarget {
            DispatchQueue.global(qos: .utility).async {
                done(Self.automationStatus(bundleID: target, askUser: false))
            }
            return
        }
        switch spec.id {
        case "location":
            done(Self.locationStatus(locationManager.authorizationStatus))
        case "notifications":
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .notDetermined: done(.notDetermined)
                case .denied: done(.denied)
                default: done(.granted)
                }
            }
        case "accessibility":
            done(AXIsProcessTrusted() ? .granted : .denied)
        case "calendars": done(Self.eventKitStatus(.event))
        case "reminders": done(Self.eventKitStatus(.reminder))
        case "contacts":
            done(Self.map(CNContactStore.authorizationStatus(for: .contacts).rawValue, granted: [3, 4], undecided: 0))
        case "photos":
            done(Self.photosStatus())
        case "camera": done(Self.captureStatus(.video))
        case "microphone": done(Self.captureStatus(.audio))
        case "bluetooth":
            switch CBCentralManager.authorization {
            case .allowedAlways: done(.granted)
            case .notDetermined: done(.notDetermined)
            default: done(.denied)
            }
        case "speech":
            done(Self.map(SFSpeechRecognizer.authorizationStatus().rawValue, granted: [3], undecided: 0))
        case "fullDisk":
            done(Self.fullDiskStatus())
        case "screenRecording":
            done(CGPreflightScreenCaptureAccess() ? .granted : .denied)
        case "inputMonitoring":
            done(CGPreflightListenEventAccess() ? .granted : .denied)
        default:
            done(.unknown)
        }
    }

    /// Maps an authorization enum's raw value: `0` is "not determined" for every framework that
    /// shares this layout (0 undecided, 1 restricted, 2 denied, 3+ granted variants).
    private static func map(_ raw: Int, granted: Set<Int>, undecided: Int) -> PermissionStatus {
        if raw == undecided { return .notDetermined }
        return granted.contains(raw) ? .granted : .denied
    }

    static func locationStatus(_ status: CLAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        default: return .granted
        }
    }

    private static func eventKitStatus(_ type: EKEntityType) -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: type) {
        case .notDetermined: return .notDetermined
        case .fullAccess, .authorized: return .granted
        default: return .denied
        }
    }

    private static func photosStatus() -> PermissionStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return .notDetermined
        case .authorized, .limited: return .granted
        default: return .denied
        }
    }

    private static func captureStatus(_ type: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        default: return .denied
        }
    }

    /// Full Disk Access has no API. A protected file either opens, is refused (EPERM) or is absent.
    private static func fullDiskStatus() -> PermissionStatus {
        let path = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
        let descriptor = open(path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        return errno == EPERM || errno == EACCES ? .denied : .unknown
    }

    /// `askUser: false` only reads the current decision; `true` shows the system prompt (blocking,
    /// so call it off the main thread). The target must be running or macOS answers -600.
    nonisolated static func automationStatus(bundleID: String, askUser: Bool) -> PermissionStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = descriptor.aeDesc else { return .unknown }
        let result = AEDeterminePermissionToAutomateTarget(
            address, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser
        )
        switch Int(result) {
        case 0: return .granted
        case -1743: return .denied                 // errAEEventNotPermitted
        case -1744: return .notDetermined          // errAEEventWouldRequireUserConsent
        default: return .unknown                   // procNotFound (-600): target not running
        }
    }

    // MARK: - Requesting

    /// Shows the system prompt where one exists; otherwise opens the right Settings pane.
    public func request(_ spec: PermissionSpec) {
        let current = status(for: spec)

        if let target = spec.automationTarget {
            requestAutomation(spec, bundleID: target)
            return
        }

        switch (spec.id, current) {
        case ("location", .notDetermined):
            locationManager.requestWhenInUseAuthorization()
        case ("notifications", .notDetermined):
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        case ("accessibility", _):
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            openSettings(spec)
        case ("calendars", .notDetermined):
            EKEventStore().requestFullAccessToEvents { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        case ("reminders", .notDetermined):
            EKEventStore().requestFullAccessToReminders { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        case ("contacts", .notDetermined):
            CNContactStore().requestAccess(for: .contacts) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        case ("photos", .notDetermined):
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        case ("camera", .notDetermined):
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        case ("microphone", .notDetermined):
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        case ("bluetooth", .notDetermined):
            // Creating the manager is what triggers the prompt.
            bluetooth = CBCentralManager(delegate: nil, queue: nil)
        case ("speech", .notDetermined):
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in Task { @MainActor in self?.refresh() } }
        case ("screenRecording", .denied), ("screenRecording", .notDetermined):
            _ = CGRequestScreenCaptureAccess()
            openSettings(spec)
        case ("inputMonitoring", .denied), ("inputMonitoring", .notDetermined):
            _ = CGRequestListenEventAccess()
            openSettings(spec)
        default:
            openSettings(spec)
        }
    }

    /// Automation only lists an app after a real Apple Event was sent, so the prompt is fired
    /// here on purpose. The target has to be running for macOS to evaluate it, so launch it first.
    private func requestAutomation(_ spec: PermissionSpec, bundleID: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard running.isEmpty else {
            askAutomation(spec, bundleID: bundleID)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            openSettings(spec)   // not installed: nothing to prompt for
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.askAutomation(spec, bundleID: bundleID)
            }
        }
    }

    private func askAutomation(_ spec: PermissionSpec, bundleID: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.automationStatus(bundleID: bundleID, askUser: true)
            Task { @MainActor in
                self?.states[spec.id] = result
                // Already denied earlier: the prompt will not return, so send them to the pane.
                if result == .denied { self?.openSettings(spec) }
            }
        }
    }

    @discardableResult
    public func openSettings(_ spec: PermissionSpec) -> Bool {
        guard let anchor = spec.anchor,
              let url = URL(string: "x-apple.systempreferences:\(anchor)")
        else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// The button label for a row.
    public func actionTitle(for spec: PermissionSpec) -> String {
        switch status(for: spec) {
        case .notDetermined: return "Allow"
        case .unknown where spec.automationTarget != nil: return "Allow"
        default: return "Open Settings"
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }
}
