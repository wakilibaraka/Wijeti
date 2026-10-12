import Foundation

/// The name and category a user gave an imported widget.
///
/// Keyed by the widget's top-level *folder name*, never by the server's widget id: the id is
/// derived from the path, so renaming the folder would change it and orphan the widget's
/// settings. A display name lives here instead and the folder stays put.
public struct UserWidgetMeta: Codable, Equatable, Sendable {
    public var title: String?
    public var category: String?

    public init(title: String? = nil, category: String? = nil) {
        self.title = title
        self.category = category
    }
}

public final class UserWidgetStore {
    public static let fileName = "UserWidgets.json"

    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [String: UserWidgetMeta] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: UserWidgetMeta].self, from: data)) ?? [:]
    }

    public func set(_ meta: UserWidgetMeta, for folder: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = (try? JSONDecoder().decode([String: UserWidgetMeta].self, from: Data(contentsOf: url))) ?? [:]
        all[folder] = meta
        try write(all)
    }

    public func remove(folder: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = (try? JSONDecoder().decode([String: UserWidgetMeta].self, from: Data(contentsOf: url))) ?? [:]
        guard all.removeValue(forKey: folder) != nil else { return }
        try write(all)
    }

    private func write(_ all: [String: UserWidgetMeta]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: url, options: .atomic)
    }

    /// A readable default name for a freshly imported folder or file: `my-clock.widget` → `My Clock`.
    public static func defaultTitle(forFolder folder: String) -> String {
        var name = folder
        for suffix in [".widget", ".jsx", ".coffee", ".js", ".html", ".htm"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        let words = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? folder : words.joined(separator: " ")
    }
}
