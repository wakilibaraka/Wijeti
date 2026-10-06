import Foundation

/// Persists per-widget settings as JSON, written atomically so a crash mid-write cannot
/// leave a truncated file that the next launch would reject.
public final class SettingsStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public var fileURL: URL { url }

    public func load() -> [String: WidgetSettings] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? decoder.decode([String: WidgetSettings].self, from: data)) ?? [:]
    }

    public func save(_ settings: [String: WidgetSettings]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(settings)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public func update(_ widgetID: String, _ mutate: (inout WidgetSettings) -> Void) throws -> WidgetSettings {
        var all = load()
        var settings = all[widgetID] ?? WidgetSettings()
        mutate(&settings)
        all[widgetID] = settings
        try save(all)
        return settings
    }
}
