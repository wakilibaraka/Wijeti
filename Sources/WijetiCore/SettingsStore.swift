import Foundation

/// Persists per-widget settings as JSON, written atomically so a crash mid-write cannot
/// leave a truncated file that the next launch would reject.
public final class SettingsStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Serializes read-modify-write so two `update` calls cannot overwrite each other.
    private let lock = NSRecursiveLock()

    public init(url: URL) {
        self.url = url
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public var fileURL: URL { url }

    public func load() -> [String: WidgetSettings] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            return try decoder.decode([String: WidgetSettings].self, from: data)
        } catch {
            quarantineCorruptFile()
            return [:]
        }
    }

    /// Moves an unreadable settings file aside so the next write cannot silently destroy it.
    private func quarantineCorruptFile() {
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        NSLog("settings file was unreadable and was moved to %@", backup.lastPathComponent)
    }

    public func save(_ settings: [String: WidgetSettings]) throws {
        lock.lock(); defer { lock.unlock() }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keys this version does not know about (written by a newer app or by the server) are
        // carried over per widget instead of being dropped by the typed round trip.
        let existing = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        var merged: [String: Any] = [:]
        for (id, value) in settings {
            var entry = existing[id] as? [String: Any] ?? [:]
            let encoded = try encoder.encode(value)
            if let fresh = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
                entry.merge(fresh) { _, new in new }
            }
            merged[id] = entry
        }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public func update(_ widgetID: String, _ mutate: (inout WidgetSettings) -> Void) throws -> WidgetSettings {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        var settings = all[widgetID] ?? WidgetSettings()
        mutate(&settings)
        all[widgetID] = settings
        try save(all)
        return settings
    }
}
