import Foundation

/// One entry in the widget library: a bundled preset the user can install with one click.
public struct Preset: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let category: String
    public let description: String
    public let entry: String
    public let source: String

    public init(
        id: String,
        title: String,
        category: String,
        description: String,
        entry: String,
        source: String
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.description = description
        self.entry = entry
        self.source = source
    }

    /// A folder with no entry file is not a widget; the catalog hides it rather than
    /// offering something that cannot load.
    public var isUsable: Bool { !entry.isEmpty && !id.isEmpty }
}

/// The bundled widget library, grouped for the picker UI.
public struct PresetCatalog: Codable, Equatable, Sendable {
    public let presets: [Preset]

    public init(presets: [Preset]) {
        self.presets = presets
    }

    /// Category order for the sidebar. Anything unlisted sorts after these, alphabetically.
    static let preferredOrder = [
        "Weather", "Calendar", "Clock", "System", "Music", "Media",
        "Finance", "Productivity", "Social", "Developer", "Fun", "Other",
    ]

    public struct Group: Identifiable, Equatable, Sendable {
        public let category: String
        public let presets: [Preset]
        public var id: String { category }

        public init(category: String, presets: [Preset]) {
            self.category = category
            self.presets = presets
        }
    }

    /// Groups sorted by `preferredOrder`, each group's presets sorted by title.
    public var groups: [Group] {
        let buckets = Dictionary(grouping: presets.filter(\.isUsable), by: \.category)
        let known = Self.preferredOrder.filter { buckets[$0] != nil }
        let extra = buckets.keys.filter { !Self.preferredOrder.contains($0) }.sorted()
        return (known + extra).map { category in
            Group(
                category: category,
                presets: (buckets[category] ?? []).sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            )
        }
    }

    public var isEmpty: Bool { presets.isEmpty }

    /// Loads `Catalog.json` from a presets directory. A missing or malformed catalog is
    /// not fatal — the app still runs, it just has no library to show.
    public static func load(from directory: URL) -> PresetCatalog {
        let url = directory.appendingPathComponent("Catalog.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Preset].self, from: data)
        else {
            return PresetCatalog(presets: [])
        }
        return PresetCatalog(presets: decoded)
    }
}
