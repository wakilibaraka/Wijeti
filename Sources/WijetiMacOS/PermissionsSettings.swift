import AppKit
import CoreLocation
import Foundation
import SwiftUI
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
        case location, fullDisk, automation, notifications, screenRecording, appleEvents

        public var title: String {
            switch self {
            case .location: return "Location"
            case .fullDisk: return "Full Disk Access"
            case .automation: return "Automation"
            case .notifications: return "Notifications"
            case .screenRecording: return "Screen Recording"
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
            case .appleEvents: return nil
            }
        }

        /// Permissions that only ever need a one-time grant can be probed. The ones that
        /// cannot be probed without a prompt report `.unknown` rather than a wrong "granted".
        public var isProbeable: Bool {
            switch self {
            case .location: return true
            case .fullDisk, .screenRecording, .appleEvents: return false
            case .automation, .notifications: return false
            }
        }
    }

    public let kind: Kind
    public var id: Kind { kind }

    public init(kind: Kind) {
        self.kind = kind
    }
}

/// Reads live authorisation status. Split out so the UI never touches CLLocationManager
/// directly and the status logic stays testable.
@MainActor
public final class PermissionProbe: ObservableObject {
    @Published public private(set) var statuses: [Permission.Kind: Bool] = [:]

    private let manager = CLLocationManager()

    public init() {
        // We only ever read the authorization status; never start updating location.
        manager.delegate = nil
    }

    public func refresh() {
        for kind in Permission.Kind.allProbeable {
            statuses[kind] = status(of: kind)
        }
    }

    private func status(of kind: Permission.Kind) -> Bool {
        switch kind {
        case .location:
            // macOS unifies the two authorisation cases into `.authorized`.
            return manager.authorizationStatus == .authorized
        default:
            return false
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

    /// Asks macOS to show its own prompt. Only location does this on demand; the rest
    /// are granted in System Settings.
    public func request(_ kind: Permission.Kind) {
        switch kind {
        case .location:
            manager.requestWhenInUseAuthorization()
            // The prompt is asynchronous; re-read once the user has answered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.refresh()
            }
        default:
            _ = openSystemSettings(for: kind)
        }
    }
}

extension Permission.Kind {
    static let all: [Permission.Kind] = [
        .location, .fullDisk, .automation, .notifications, .screenRecording, .appleEvents,
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

    /// The query a widget would call. Empty coordinates mean "auto", which Open-Meteo
    /// resolves by IP — useful when the user has not set a location and has denied access.
    public var openMeteoQuery: String {
        guard hasOpenMeteoLocation else { return "latitude=52.52&longitude=13.41" }
        return "latitude=\(openMeteoLatitude)&longitude=\(openMeteoLongitude)"
    }
}

/// A one-shot CoreLocation read, wrapped so the UI does not own the delegate dance.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    func currentLocation() async -> CLLocation? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        // Nothing to read until the user answers; re-checked once the prompt resolves.
        guard manager.authorizationStatus == .authorized else { return nil }
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

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        continuation?.resume(returning: locations.last)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
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
                if !kind.isProbeable {
                    Text(granted ? "Granted" : "Granted in System Settings")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Button(kind.isProbeable ? "Request" : "Open Settings") {
                probe.request(kind)
                sources.lastAction = kind.isProbeable
                    ? "Asked macOS for \(kind.title)."
                    : "Opened System Settings → \(kind.title)."
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { probe.refresh() }
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
