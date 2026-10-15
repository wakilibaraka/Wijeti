import AppKit
import CoreLocation
import Foundation
import SwiftUI
import WijetiCore

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
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // No second "Permissions" heading here: the pane heading above already names the
                // pane, so this row is the explanation plus its one action.
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Widgets are scripts, so they can ask for almost any access. Grant only what the "
                         + "widgets you use need. macOS prompts once per app; some permissions can only be "
                         + "switched on by hand in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Refresh") { probe.refresh() }
                        .controlSize(.small)
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search permissions", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))

                ForEach(PermissionSpec.Group.allCases, id: \.self) { group in
                    let specs = PermissionCatalog.specs(in: group).filter { $0.matches(query) }
                    if !specs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            VStack(spacing: 0) {
                                ForEach(Array(specs.enumerated()), id: \.element.id) { index, spec in
                                    permissionRow(spec)
                                    if index < specs.count - 1 { Divider().padding(.leading, 12) }
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            if group == .automation {
                                Text("Automation targets are listed under System Settings → Privacy & Security → Automation only after you press Allow here.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

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

    private func permissionRow(_ spec: PermissionSpec) -> some View {
        let status = probe.status(for: spec)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.title).font(.callout.weight(.medium))
                Text(spec.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            PermissionBadge(status: status)

            Button(probe.actionTitle(for: spec)) {
                probe.request(spec)
                sources.lastAction = "Asked macOS for \(spec.title)."
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
