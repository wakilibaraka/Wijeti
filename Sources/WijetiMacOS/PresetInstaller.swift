import Foundation

/// Installs the `.jsx` presets bundled with the app into the widget directory.
///
/// Presets are copied, never moved, and an existing file of the same name is left alone —
/// re-running the installer after editing your own copy must not clobber it.
public enum PresetInstaller {
    public struct Result {
        public let installed: [String]
        public let skipped: [String]
    }

    /// Top-level entries in the presets directory: `.jsx` files and widget folders such as
    /// `liquid-glass-calendar.widget` (a folder containing `index.jsx`).
    public static func entries(in presetsDirectory: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: presetsDirectory.path)) ?? []
        return contents
            .filter { $0.hasSuffix(".jsx") || $0.hasSuffix(".widget") }
            .sorted()
    }

    @discardableResult
    public static func install(
        from presetsDirectory: URL,
        to widgetDirectory: URL
    ) throws -> Result {
        var installed: [String] = []
        var skipped: [String] = []

        guard FileManager.default.fileExists(atPath: presetsDirectory.path) else {
            return Result(installed: installed, skipped: skipped)
        }
        try FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)

        for name in entries(in: presetsDirectory) {
            let destination = widgetDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                skipped.append(name)
                continue
            }
            try FileManager.default.copyItem(
                at: presetsDirectory.appendingPathComponent(name),
                to: destination
            )
            installed.append(name)
        }
        return Result(installed: installed, skipped: skipped)
    }
}
