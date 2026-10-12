import Foundation

/// Safely unpacks a user-supplied `.zip` into a scratch directory.
///
/// Archives come from the internet, so nothing is trusted: entry names are checked before
/// extraction, the archive is size- and count-limited, and anything that turns out to be a
/// symlink is refused afterwards (a link inside a watched widget folder could point at any
/// file the user can read).
public struct WidgetArchive: Sendable {
    public enum ArchiveError: LocalizedError, Equatable {
        case unreadable(String)
        case unsafeEntry(String)
        case tooManyEntries(Int)
        case tooLarge(Int64)
        case containsSymlink(String)
        case extractionFailed(String)
        case timedOut
        case empty

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return "The archive couldn’t be read (\(detail))."
            case .unsafeEntry(let name): return "The archive contains an unsafe path: \(name)."
            case .tooManyEntries(let count): return "The archive has too many files (\(count))."
            case .tooLarge(let bytes): return "The archive is too large when unpacked (\(bytes / 1_000_000) MB)."
            case .containsSymlink(let name): return "The archive contains a symbolic link: \(name)."
            case .extractionFailed(let detail): return "Unzipping failed (\(detail))."
            case .timedOut: return "Unzipping took too long and was cancelled."
            case .empty: return "The archive is empty."
            }
        }
    }

    public var unzipExecutable: URL
    public var maxEntries: Int
    public var maxUncompressedBytes: Int64
    public var timeout: TimeInterval

    public init(
        unzipExecutable: URL = URL(fileURLWithPath: "/usr/bin/unzip"),
        maxEntries: Int = 5_000,
        maxUncompressedBytes: Int64 = 200_000_000,
        timeout: TimeInterval = 60
    ) {
        self.unzipExecutable = unzipExecutable
        self.maxEntries = maxEntries
        self.maxUncompressedBytes = maxUncompressedBytes
        self.timeout = timeout
    }

    /// Names that must never be extracted: absolute, drive-like, or climbing out with `..`.
    public static func isSafeEntryName(_ name: String) -> Bool {
        if name.isEmpty || name.hasPrefix("/") || name.hasPrefix("~") || name.contains("\0") { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    /// Entries macOS adds when zipping from Finder; they are never part of a widget.
    static func isMetadata(_ name: String) -> Bool {
        name.hasPrefix("__MACOSX/") || name == "__MACOSX" || name.hasSuffix(".DS_Store")
    }

    /// Unpacks `zipURL` into a fresh directory under `scratch` and returns the URLs the
    /// importer should install. The caller owns (and should delete) the directory returned
    /// by `scratchDirectory`.
    public func extract(_ zipURL: URL, into scratchDirectory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        try validateListing(of: zipURL)

        let extraction = try run(["-q", "-o", zipURL.path, "-x", "__MACOSX/*", "*.DS_Store", "-d", scratchDirectory.path])
        guard extraction.status == 0 else {
            throw ArchiveError.extractionFailed(Self.firstLine(extraction.output))
        }

        try rejectSymlinks(in: scratchDirectory)

        let contents = ((try? fileManager.contentsOfDirectory(atPath: scratchDirectory.path)) ?? [])
            .filter { !Self.isMetadata($0) }
            .sorted()
        guard !contents.isEmpty else { throw ArchiveError.empty }

        // One top-level folder means the zip wrapped the widget; install the folder itself.
        if contents.count == 1 {
            let only = scratchDirectory.appendingPathComponent(contents[0])
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: only.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return [only]
            }
        }
        return contents.map { scratchDirectory.appendingPathComponent($0) }
    }

    // MARK: - Validation

    private func validateListing(of zipURL: URL) throws {
        let listing = try run(["-Z1", zipURL.path])
        guard listing.status == 0 else {
            throw ArchiveError.unreadable(Self.firstLine(listing.output))
        }
        let names = listing.output.split(whereSeparator: \.isNewline).map(String.init)
        guard names.count <= maxEntries else { throw ArchiveError.tooManyEntries(names.count) }
        for name in names where !Self.isSafeEntryName(name) {
            throw ArchiveError.unsafeEntry(name)
        }

        // `-t` reports the uncompressed total in the last line of `unzip -l`.
        let sizes = try run(["-l", zipURL.path])
        if sizes.status == 0, let total = Self.totalBytes(fromListing: sizes.output), total > maxUncompressedBytes {
            throw ArchiveError.tooLarge(total)
        }
    }

    static func totalBytes(fromListing output: String) -> Int64? {
        guard let last = output.split(whereSeparator: \.isNewline).last else { return nil }
        let first = last.split(separator: " ", omittingEmptySubsequences: true).first
        return first.flatMap { Int64($0) }
    }

    private func rejectSymlinks(in directory: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                let relative = String(url.path.dropFirst(directory.path.count + 1))
                try? fileManager.removeItem(at: directory)
                throw ArchiveError.containsSymlink(relative)
            }
        }
    }

    // MARK: - Process

    private struct Output {
        var status: Int32
        var output: String
    }

    /// Runs `unzip`, draining its output as it arrives (an unread pipe deadlocks after 64 KB)
    /// and killing it if it outlives `timeout`.
    private func run(_ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = unzipExecutable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lock = NSLock()
        var collected = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            lock.lock(); collected.append(chunk); lock.unlock()
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ArchiveError.extractionFailed(error.localizedDescription)
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ArchiveError.timedOut
        }
        // Let the handler drain what is left in the pipe.
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        collected.append(tail)
        let text = String(decoding: collected, as: UTF8.self)
        lock.unlock()
        return Output(status: process.terminationStatus, output: text)
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no details"
    }
}
