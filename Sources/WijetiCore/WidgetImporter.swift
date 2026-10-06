import Foundation

/// Imports widgets from anywhere on disk — a dropped folder, a picked `.jsx`, a zip's
/// worth of loose files — into the widget directory the server watches.
///
/// The point is that a user never has to know where that directory is: the library UI
/// hands URLs straight to `importWidgets(at:)`.
public struct WidgetImporter: Equatable, Sendable {
    public let widgetDirectory: URL
    public let fileManager: FileManager

    public init(widgetDirectory: URL, fileManager: FileManager = .default) {
        self.widgetDirectory = widgetDirectory
        self.fileManager = fileManager
    }

    public struct Result: Equatable, Sendable {
        public struct Failure: Equatable, Sendable {
            public let url: URL
            public let reason: String
        }

        public var installed: [String]
        public var skipped: [String]
        public var failures: [Failure]
    }

    public enum ImportError: LocalizedError, Equatable {
        case notAWidget(String)
        case destinationExists(String)

        public var errorDescription: String? {
            switch self {
            case let .notAWidget(name):
                return "\(name) has no index.jsx, index.coffee or index.js."
            case let .destinationExists(name):
                return "\(name) is already installed."
            }
        }
    }

    static let entryNames = ["index.jsx", "index.coffee", "index.js"]
    static let entryExtensions = ["jsx", "coffee", "js"]

    /// The server derives widget ids from the path: the widget's location relative to the
    /// root, with `/` and `.` turned into `-` (`server/src/resolveWidget.js`). We must match
    /// it exactly, or the UI would show one name and the settings file would use another.
    public static func widgetID(for filePath: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        var path = filePath.standardizedFileURL.path
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
        return Self.entryExtensions.contains(url.pathExtension.lowercased())
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
            } catch {
                result.failures.append(Result.Failure(url: url, reason: error.localizedDescription))
            }
        }
        return result
    }

    /// Removes an installed widget and reports the id the server will drop.
    @discardableResult
    public func removeWidget(named name: String) -> String? {
        let destination = widgetDirectory.appendingPathComponent(name)
        guard entryFile(in: destination) != nil else { return nil }
        try? fileManager.removeItem(at: destination)
        return Self.widgetID(for: destination, root: widgetDirectory)
    }

    /// The file the server treats as the widget's entry point, if there is one.
    public func entryFile(in directory: URL) -> String? {
        for name in Self.entryNames where fileManager.fileExists(
            atPath: directory.appendingPathComponent(name).path
        ) {
            return name
        }
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.sorted().first { Self.entryExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
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
