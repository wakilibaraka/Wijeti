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
    public static let preferredOrder = [
        "Weather", "Calendar", "Clock", "System", "Music", "Lyrics", "Media",
        "Finance", "Productivity", "Social", "Developer", "Fun", "Quotes", "Other",
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

    /// What a load attempt actually found, and — when it found nothing — why.
    ///
    /// The app used to answer this question with an empty list and no explanation, so a
    /// library that failed to load looked exactly like a library that shipped empty. Every
    /// failure below carries a sentence the UI can show.
    public struct LoadReport {
        public let directory: URL
        public let presets: [Preset]
        /// Catalog entries that could not be decoded, so a half-broken `Catalog.json` costs
        /// one row instead of the whole library.
        public let skipped: [String]
        /// `nil` when the catalog was read as written; otherwise why it was not.
        public let problem: String?
    }

    /// Loads `Catalog.json` from a presets directory, and falls back to reading the
    /// directory itself when the file is missing, unreadable or broken.
    ///
    /// A missing or malformed catalog is not fatal — the app still runs. It should not,
    /// however, silently pretend the user has no widgets when the folders are sitting right
    /// there: the fallback rebuilds the library from what is on disk, and `problem` records
    /// what went wrong so the empty state can say so.
    public static func loadReport(
        from directory: URL,
        log: (String) -> Void = { _ in }
    ) -> LoadReport {
        let directory = directory.canonicalPathURL
        let url = directory.appendingPathComponent("Catalog.json")
        let data = try? Data(contentsOf: url)
        let onDisk = entriesOnDisk(in: directory)

        var decoded: [Preset] = []
        var skipped: [String] = []
        var problem: String?

        if let data {
            if let raw = try? JSONSerialization.jsonObject(with: data),
               let rows = raw as? [[String: Any]] {
                let decoder = JSONDecoder()
                for (index, row) in rows.enumerated() {
                    let name = row["id"] as? String ?? "entry \(index)"
                    guard let entryData = try? JSONSerialization.data(withJSONObject: row),
                          let preset = try? decoder.decode(Preset.self, from: entryData)
                    else {
                        skipped.append(name)
                        continue
                    }
                    decoded.append(preset)
                }
                if decoded.isEmpty, !rows.isEmpty {
                    problem = "Catalog.json has \(rows.count) entr\(rows.count == 1 ? "y" : "ies") "
                        + "but none could be read."
                }
            } else {
                problem = "Catalog.json is not a readable list of widgets."
            }
        } else {
            problem = FileManager.default.fileExists(atPath: directory.path)
                ? "Catalog.json is missing."
                : "The widget library folder does not exist."
        }

        // The folders are the source of truth. If the manifest yielded nothing, read it off
        // the filesystem rather than showing an empty library.
        if decoded.isEmpty, !onDisk.isEmpty {
            decoded = onDisk
        }

        for name in skipped {
            log("catalog: skipped unreadable entry \"\(name)\"")
        }
        log(
            "catalog: \(decoded.count) preset(s) from \(directory.logPath)"
                + (problem.map { " — \($0)" } ?? "")
        )

        return LoadReport(
            directory: directory,
            presets: decoded.filter(\.isUsable),
            skipped: skipped,
            problem: problem
        )
    }

    /// Loads `Catalog.json` from a presets directory. A missing or malformed catalog is
    /// not fatal — the app still runs, it just has no library to show.
    public static func load(from directory: URL) -> PresetCatalog {
        PresetCatalog(presets: loadReport(from: directory).presets)
    }

    /// Presets rebuilt from the directory listing: every `.widget` folder with an entry file,
    /// plus loose `.jsx`/`.js`/`.coffee` files. Ids match the names on disk, which is what
    /// `Catalog.json` uses and what `PresetInstaller` copies.
    static func entriesOnDisk(in directory: URL) -> [Preset] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && $0 != "Catalog.json" }
            .sorted()
            .compactMap { name in
                let item = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else {
                    return nil
                }
                if isDirectory.boolValue {
                    guard name.hasSuffix(".widget"),
                          let entry = WidgetImporter.entryFile(in: item)
                    else { return nil }
                    return Preset(
                        id: name,
                        title: title(for: name),
                        category: "Other",
                        description: "",
                        entry: entry,
                        source: "Wijeti"
                    )
                }
                guard WidgetImporter.entryExtensions.contains(item.pathExtension.lowercased()) else {
                    return nil
                }
                return Preset(
                    id: name,
                    title: title(for: name),
                    category: "Other",
                    description: "",
                    entry: name,
                    source: "Wijeti"
                )
            }
    }

    /// `liquid-glass-calendar.widget` -> "Liquid Glass Calendar", for presets discovered on
    /// disk that have no catalog row to take a title from.
    static func title(for name: String) -> String {
        var base = name
        for suffix in [".widget", ".jsx", ".js", ".coffee"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }
        return base
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
