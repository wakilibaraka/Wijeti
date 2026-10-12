import AppKit
import CoreLocation
import Foundation
import ApplicationServices
import SwiftUI
import UserNotifications
import WijetiCore

/// A permission Wijeti may need, and how to obtain it.
///
/// Widgets ask for all sorts of access — location for weather, the network for APIs,
/// Automation to drive other apps, Full Disk Access to read files a widget wants. The
/// app cannot grant any of these itself: macOS only ever prompts, and several (Location,
/// Full Disk Access) must be granted by hand in System Settings. What Wijeti can do is
/// ask in the right order, check the current status honestly, and open the exact pane
/// the user needs to visit.
public struct Permission: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case location, notifications, accessibility, fullDisk, automation, screenRecording, appleEvents

        public var title: String {
            switch self {
            case .location: return "Location"
            case .fullDisk: return "Full Disk Access"
            case .automation: return "Automation"
            case .notifications: return "Notifications"
            case .screenRecording: return "Screen Recording"
            case .accessibility: return "Accessibility"
            case .appleEvents: return "Scripting (Apple Events)"
            }
        }

        /// Why a widget on the desktop might need this.
        public var reason: String {
            switch self {
            case .location:
                return "Weather widgets and anything that reports where you are."
            case .fullDisk:
                return "Widgets that read files outside your home folder, such as music or photo libraries."
            case .automation:
                return "Widgets that control other apps, such as toggling a music player."
            case .notifications:
                return "Background refreshes and alerts from widgets."
            case .accessibility:
                return "Widgets that read window titles or react to keyboard and app focus."
            case .screenRecording:
                return "Only needed to capture the desktop itself; ordinary widgets do not need it."
            case .appleEvents:
                return "Lets your own scripts drive Wijeti through AppleScript."
            }
        }

        /// `x-apple.systempreferences` anchor for the pane that grants this, if one exists.
        public var systemSettingsAnchor: String? {
            switch self {
            case .location: return "com.apple.preference.security?Privacy_LocationServices"
            case .fullDisk: return "com.apple.preference.security?Privacy_AllFiles"
            case .automation: return "com.apple.preference.security?Privacy_Automation"
            case .notifications: return "com.apple.preference.notifications"
            case .screenRecording: return "com.apple.preference.security?Privacy_ScreenCapture"
            case .accessibility: return "com.apple.preference.security?Privacy_Accessibility"
            case .appleEvents: return nil
            }
        }

        /// Permissions that only ever need a one-time grant can be probed. The ones that
        /// cannot be probed without a prompt report `.unknown` rather than a wrong "granted".
        public var isProbeable: Bool {
            switch self {
            case .location, .notifications, .accessibility: return true
            case .fullDisk, .screenRecording, .appleEvents, .automation: return false
            }
        }
    }

    public let kind: Kind
    public var id: Kind { kind }

    public init(kind: Kind) {
        self.kind = kind
    }
}

/// How a permission currently stands, as far as macOS lets us tell without prompting.
public enum PermissionStatus: Equatable, Sendable {
    case granted, notDetermined, denied
    /// Cannot be read without side effects (Full Disk Access, Automation, …).
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

/// Reads live authorisation status. Split out so the UI never touches CLLocationManager
/// directly and the status logic stays testable.
///
/// Refreshes itself whenever the app becomes active, which is how a change made in System
/// Settings shows up as soon as the user switches back.
@MainActor
public final class PermissionProbe: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public private(set) var states: [Permission.Kind: PermissionStatus] = [:]

    private let manager = CLLocationManager()
    private var activeObserver: NSObjectProtocol?

    public override init() {
        super.init()
        manager.delegate = self
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

    /// Boolean view kept for callers that only care whether access is granted.
    public var statuses: [Permission.Kind: Bool] {
        states.mapValues { $0 == .granted }
    }

    public func status(for kind: Permission.Kind) -> PermissionStatus {
        states[kind] ?? .unknown
    }

    public func refresh() {
        for kind in Permission.Kind.all where !kind.isProbeable {
            states[kind] = .unknown
        }
        states[.location] = Self.locationStatus(manager.authorizationStatus)
        states[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status: PermissionStatus
            switch settings.authorizationStatus {
            case .notDetermined: status = .notDetermined
            case .denied: status = .denied
            default: status = .granted
            }
            Task { @MainActor in self?.states[.notifications] = status }
        }
    }

    static func locationStatus(_ status: CLAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        default: return .granted   // authorizedAlways (and the legacy authorized)
        }
    }

    /// Opens the System Settings pane for a permission.
    @discardableResult
    public func openSystemSettings(for kind: Permission.Kind) -> Bool {
        guard let anchor = kind.systemSettingsAnchor,
              let url = URL(string: "x-apple.systempreferences:\(anchor)")
        else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Asks macOS to show its own prompt where one exists; otherwise opens the right pane.
    public func request(_ kind: Permission.Kind) {
        switch (kind, status(for: kind)) {
        case (.location, .notDetermined):
            manager.requestWhenInUseAuthorization()
        case (.notifications, .notDetermined):
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        case (.accessibility, .denied):
            // Registers the app in the Accessibility list, then shows the pane.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            _ = openSystemSettings(for: kind)
        default:
            _ = openSystemSettings(for: kind)
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }
}

extension Permission.Kind {
    static let all: [Permission.Kind] = [
        .location, .notifications, .accessibility, .fullDisk, .automation, .screenRecording, .appleEvents,
    ]

    /// Only the permissions whose status can be read without prompting.
    static let allProbeable: [Permission.Kind] = all.filter(\.isProbeable)
}

// MARK: - Data sources

/// Credentials and endpoints a widget may need, stored in `UserDefaults` rather than in
/// the settings file, so they never travel to the server or into `WidgetSettings.json`.
@MainActor
public final class DataSourceSettings: ObservableObject {
    private enum Key {
        static let openMeteoLatitude = "dataSource.openMeteo.latitude"
        static let openMeteoLongitude = "dataSource.openMeteo.longitude"
        static let openMeteoCity = "dataSource.openMeteo.city"
        static let units = "dataSource.units"
    }

    public enum Units: String, CaseIterable, Identifiable {
        case metric, imperial
        public var id: String { rawValue }
        public var title: String { self == .metric ? "Celsius, km/h" : "Fahrenheit, mph" }
    }

    @Published public var openMeteoLatitude: String {
        didSet { defaults.set(openMeteoLatitude, forKey: Key.openMeteoLatitude) }
    }
    @Published public var openMeteoLongitude: String {
        didSet { defaults.set(openMeteoLongitude, forKey: Key.openMeteoLongitude) }
    }
    @Published public var openMeteoCity: String {
        didSet { defaults.set(openMeteoCity, forKey: Key.openMeteoCity) }
    }
    @Published public var units: Units {
        didSet { defaults.set(units.rawValue, forKey: Key.units) }
    }
    /// The last permission action the view tried, shown as a caption under the list.
    @Published public var lastAction = ""

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        openMeteoLatitude = defaults.string(forKey: Key.openMeteoLatitude) ?? ""
        openMeteoLongitude = defaults.string(forKey: Key.openMeteoLongitude) ?? ""
        openMeteoCity = defaults.string(forKey: Key.openMeteoCity) ?? ""
        units = Units(rawValue: defaults.string(forKey: Key.units) ?? "") ?? .metric
    }

    public var hasOpenMeteoLocation: Bool {
        Double(openMeteoLatitude) != nil && Double(openMeteoLongitude) != nil
    }

    /// Fills the coordinates from CoreLocation, so the user does not have to type numbers.
    public func useCurrentLocation() async -> Bool {
        let service = LocationProvider()
        guard let location = await service.currentLocation() else { return false }
        openMeteoLatitude = String(format: "%.4f", location.coordinate.latitude)
        openMeteoLongitude = String(format: "%.4f", location.coordinate.longitude)
        openMeteoCity = await service.placemark(for: location)
        return true
    }
}

/// A one-shot CoreLocation read, wrapped so the UI does not own the delegate dance.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var authorizationWaiter: CheckedContinuation<Void, Never>?

    func currentLocation() async -> CLLocation? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // Wait for the user's answer instead of giving up on the first run.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                authorizationWaiter = continuation
            }
        }
        guard PermissionProbe.locationStatus(manager.authorizationStatus) == .granted else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    /// Resolves a human-readable place name. `CLGeocoder` is the reverse-geocoding entry
    /// point on macOS, and a failure here is not fatal — the coordinates are good enough.
    func placemark(for location: CLLocation) async -> String {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks?.first else { return "" }
        let parts = [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
        return parts.joined(separator: ", ")
    }

    // The conformance is `nonisolated` because `CLLocationManagerDelegate` is: declaring these
    // without it made the whole conformance cross into main-actor code, which the compiler
    // flags as a data race and which becomes an error under the Swift 6 language mode. Each
    // callback hops back explicitly instead.
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let latest = locations.last
        Task { @MainActor in
            self.continuation?.resume(returning: latest)
            self.continuation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            self.authorizationWaiter?.resume()
            self.authorizationWaiter = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(returning: nil)
            self.continuation = nil
        }
    }

}

// MARK: - View

struct PermissionsView: View {
    @ObservedObject var probe: PermissionProbe
    @ObservedObject var sources: DataSourceSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Permissions")
                    .font(.headline)

                Text("Wijeti itself needs almost nothing. These are for the widgets you add — "
                     + "macOS will only prompt once per app, and a few must be granted by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach(Array(Permission.Kind.all.enumerated()), id: \.element) { index, kind in
                        permissionRow(kind)
                        if index < Permission.Kind.all.count - 1 { Divider().padding(.leading, 12) }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

                Divider()

                Text("Data sources")
                    .font(.headline)

                Text("Widgets that call a web API read these from Wijeti's shared settings. "
                     + "Nothing is sent anywhere except the service a widget names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                openMeteoSection
                unitsSection

                if !sources.lastAction.isEmpty {
                    Text(sources.lastAction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { probe.refresh() }
    }

    private func permissionRow(_ kind: Permission.Kind) -> some View {
        let status = probe.status(for: kind)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.callout.weight(.medium))
                Text(kind.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            PermissionBadge(status: status)

            Button(status == .notDetermined ? "Allow" : "Open Settings") {
                probe.request(kind)
                sources.lastAction = status == .notDetermined
                    ? "Asked macOS for \(kind.title)."
                    : "Opened System Settings → \(kind.title)."
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private var openMeteoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Open-Meteo", systemImage: "cloud.sun")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("No key needed")
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.18)))
            }
            Text("Open-Meteo is free and keyless, so weather widgets work immediately. "
                 + "Set a location, or leave it blank to let the service guess from your network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Latitude", text: $sources.openMeteoLatitude)
                    .textFieldStyle(.roundedBorder)
                TextField("Longitude", text: $sources.openMeteoLongitude)
                    .textFieldStyle(.roundedBorder)
                Button("Use My Location") {
                    Task {
                        let ok = await sources.useCurrentLocation()
                        sources.lastAction = ok
                            ? "Location set to \(sources.openMeteoLatitude), \(sources.openMeteoLongitude)."
                            : "Location unavailable — allow Location access, or type coordinates."
                    }
                }
            }
            if !sources.openMeteoCity.isEmpty {
                Text(sources.openMeteoCity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Units").font(.callout.weight(.medium))
            Picker("Units", selection: $sources.units) {
                ForEach(DataSourceSettings.Units.allCases) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
        }
    }
}
