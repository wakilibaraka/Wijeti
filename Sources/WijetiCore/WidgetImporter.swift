#if canImport(Darwin)
import Darwin
#endif
import Foundation

public extension URL {
    /// The path with the home folder abbreviated to `~`, for logs that may end up in bug reports.
    var logPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The canonical form of a path: symlinks resolved, `..` collapsed, existing ancestors
    /// resolved even when the tail does not exist yet.
    ///
    /// Widget ids are derived *from the path*, so one folder that can be named two ways yields
    /// two ids for one widget, and a half-matching prefix silently corrupts the id. Pointing
    /// Wijeti at a `/tmp` folder reproduced all three failures at once: the server's first scan
    /// used the path it was handed (`/tmp/…`, ids fine), while the FSEvents watcher reported the
    /// resolved path (`/private/tmp/…`). Adding a widget then produced a second id —
    /// `private-WeatherNow-widget-index-jsx`, because `filePath.replace(rootPath, '')` matched
    /// its `/tmp/…` substring mid-string and left the `/private` stump behind — and deleting one
    /// never unregistered anything, because the watcher's resolved paths no longer matched the
    /// unresolved keys it had recorded.
    ///
    /// `resolvingSymlinksInPath()` cannot fix this: Foundation treats `/tmp` as already
    /// canonical (it normalizes `/private/tmp` *to* `/tmp`), so it returns `/tmp/…` unchanged
    /// while the kernel keeps reporting `/private/tmp/…`. Only `realpath(3)` agrees with the
    /// watcher, which is why this asks it directly.
    var canonicalPathURL: URL {
        var probe = standardizedFileURL
        var tail: [String] = []
        while !probe.path.isEmpty, probe.path != "/" {
            if let resolved = Self.realPath(probe.path) {
                let base = URL(fileURLWithPath: resolved, isDirectory: probe.hasDirectoryPath)
                return tail.reversed().reduce(base) { $0.appendingPathComponent($1) }
            }
            tail.append(probe.lastPathComponent)
            probe = probe.deletingLastPathComponent()
        }
        return standardizedFileURL
    }

    /// `realpath(3)`, or `nil` when the path does not exist (the caller then resolves its
    /// nearest existing ancestor and re-appends the rest).
    private static func realPath(_ path: String) -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
        #else
        return nil
        #endif
    }
}

/// Imports widgets from anywhere on disk — a dropped folder, a picked `.jsx`, a zip's
/// worth of loose files — into the widget directory the server watches.
///
/// The point is that a user never has to know where that directory is: the library UI
/// hands URLs straight to `importWidgets(at:)`.
public struct WidgetImporter: Equatable, Sendable {
    public let widgetDirectory: URL

    /// The shared, documented thread-safe `FileManager`.
    ///
    /// This used to be an injectable stored property, which meant the struct could not honestly
    /// be `Sendable` — `FileManager` is not — and the compiler warned that the mismatch becomes
    /// an error under the Swift 6 language mode. The injection point was never once passed a
    /// non-default value, so it bought nothing and cost the conformance the rest of the core
    /// depends on.
    private var fileManager: FileManager { .default }

    public init(widgetDirectory: URL) {
        self.widgetDirectory = widgetDirectory
    }

    public struct Result: Equatable, Sendable {
        public struct Failure: Equatable, Sendable {
            public let url: URL
            public let reason: String
        }

        public var installed: [String]
        public var skipped: [String]
        public var failures: [Failure]
        /// The top-level folder each installed widget now lives in, parallel to `installed`.
        public var installedFolders: [String] = []
    }

    public enum ImportError: LocalizedError, Equatable {
        case notAWidget(String)
        case destinationExists(String)

        public var errorDescription: String? {
            switch self {
            case let .notAWidget(name):
                return "\(name) has no index.jsx, index.coffee or index.js (or isn’t a .html page)."
            case let .destinationExists(name):
                return "\(name) is already installed."
            }
        }
    }

    static let entryNames = ["index.jsx", "index.coffee", "index.js"]
    static let entryExtensions = ["jsx", "coffee", "js"]
    /// Plain web pages are accepted too: they are wrapped in a tiny widget that shows them in a frame.
    static let htmlExtensions = ["html", "htm"]

    /// The server derives widget ids from the path: the widget's location relative to the
    /// root, with `/` and `.` turned into `-` (`server/src/resolveWidget.js`). We must match
    /// it exactly, or the UI would show one name and the settings file would use another.
    public static func widgetID(for filePath: URL, root: URL) -> String {
        let rootPath = root.canonicalPathURL.path
        var path = filePath.canonicalPathURL.path
        if path.hasPrefix(rootPath) {
            path = String(path.dropFirst(rootPath.count))
        }
        // The server splits on runs of separators and drops empty parts, so a leading "/"
        // contributes nothing rather than a leading "-".
        let parts = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return parts
            .joined(separator: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: " ", with: "_")
    }

    /// True when the URL is something the server can actually load as a widget.
    public func canImport(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue {
            return entryFile(in: url) != nil
        }
        let ext = url.pathExtension.lowercased()
        return Self.entryExtensions.contains(ext) || Self.htmlExtensions.contains(ext)
    }

    /// The widget source that displays `html` in a frame. The page is embedded as a JSON string so
    /// no characters need escaping by hand, and its scripts run because a frame (unlike
    /// `innerHTML`) executes them.
    public static func htmlWrapperSource(html: String, title: String) -> String {
        let encoded = (try? JSONEncoder().encode(html)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let safeTitle = title.replacingOccurrences(of: "*/", with: "")
        return """
        // \(safeTitle): web page wrapped as a widget by Wijeti.
        export const refreshFrequency = false;

        export const className = `
          top: 40px;
          left: 40px;
          width: 480px;
          height: 320px;
          border-radius: 12px;
          overflow: hidden;
        `;

        const page = \(encoded);

        export const render = () => (
          <iframe
            srcDoc={page}
            style={{ width: '100%', height: '100%', border: 0, background: 'transparent' }}
          />
        );
        """
    }

    /// Copies each URL into the widget directory. Existing widgets of the same name are
    /// left alone rather than silently overwritten — a user's edits are theirs to keep.
    public func importWidgets(at urls: [URL]) throws -> Result {
        var result = Result(installed: [], skipped: [], failures: [])
        try fileManager.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)

        for url in urls {
            let name = url.lastPathComponent
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                result.failures.append(Result.Failure(url: url, reason: "No longer exists."))
                continue
            }

            let destination: URL
            if isDirectory.boolValue {
                guard entryFile(in: url) != nil else {
                    result.failures.append(
                        Result.Failure(url: url, reason: ImportError.notAWidget(name).localizedDescription)
                    )
                    continue
                }
                destination = widgetDirectory.appendingPathComponent(name)
            } else if Self.htmlExtensions.contains(url.pathExtension.lowercased()) {
                let stem = url.deletingPathExtension().lastPathComponent
                let folder = widgetDirectory.appendingPathComponent("\(stem).widget")
                if fileManager.fileExists(atPath: folder.path) {
                    result.skipped.append(folder.lastPathComponent)
                    continue
                }
                do {
                    let html = try String(contentsOf: url, encoding: .utf8)
                    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Self.htmlWrapperSource(html: html, title: stem)
                        .write(to: folder.appendingPathComponent("index.jsx"), atomically: true, encoding: .utf8)
                    result.installed.append(
                        Self.widgetID(for: folder.appendingPathComponent("index.jsx"), root: widgetDirectory)
                    )
                    result.installedFolders.append(folder.lastPathComponent)
                } catch {
                    try? fileManager.removeItem(at: folder)
                    result.failures.append(Result.Failure(url: url, reason: error.localizedDescription))
                }
                continue
            } else {
                guard Self.entryExtensions.contains(url.pathExtension.lowercased()) else {
                    result.failures.append(
                        Result.Failure(url: url, reason: ImportError.notAWidget(name).localizedDescription)
                    )
                    continue
                }
                destination = widgetDirectory.appendingPathComponent(name)
            }

            if fileManager.fileExists(atPath: destination.path) {
                result.skipped.append(name)
                continue
            }

            do {
                try copy(from: url, to: destination, isDirectory: isDirectory.boolValue)
                result.installed.append(Self.widgetID(for: destination, root: widgetDirectory))
                result.installedFolders.append(destination.lastPathComponent)
            } catch {
                result.failures.append(Result.Failure(url: url, reason: error.localizedDescription))
            }
        }
        return result
    }

    /// Removes an installed widget and reports the id the server will drop.
    @discardableResult
    public func removeWidget(named name: String) -> String? {
        // A name is one path component: anything else could escape the widget directory.
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            return nil
        }
        let destination = widgetDirectory.appendingPathComponent(name)
        guard entryFile(in: destination) != nil else { return nil }
        try? fileManager.removeItem(at: destination)
        return Self.widgetID(for: destination, root: widgetDirectory)
    }

    /// The file the server treats as the widget's entry point, if there is one.
    public func entryFile(in directory: URL) -> String? {
        Self.entryFile(in: directory)
    }

    /// Static so callers that only have a directory — the catalog's on-disk fallback, for
    /// one — can ask the same question without constructing an importer.
    public static func entryFile(in directory: URL) -> String? {
        let fileManager = FileManager.default
        for name in entryNames where fileManager.fileExists(
            atPath: directory.appendingPathComponent(name).path
        ) {
            return name
        }
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.sorted().first { entryExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    private func copy(from source: URL, to destination: URL, isDirectory: Bool) throws {
        if isDirectory {
            try fileManager.copyItem(at: source, to: destination)
            return
        }
        // A bare widget file becomes a folder of its own: the server derives widget ids from
        // paths under the widget root, so `clock.jsx` is installed as `clock.jsx/clock.jsx`.
        // The folder keeps the file's full name so the id we report matches the server's.
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))
    }
}
