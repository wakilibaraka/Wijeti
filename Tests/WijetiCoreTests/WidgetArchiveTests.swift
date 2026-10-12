import XCTest
@testable import WijetiCore

final class WidgetArchiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wijeti-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds a zip with `/usr/bin/zip` from a staging folder.
    private func makeZip(named name: String, populate: (URL) throws -> Void, extraArgs: [String] = []) throws -> URL {
        let staging = root.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try populate(staging)
        let zip = root.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        process.arguments = ["-q", "-r"] + extraArgs + [zip.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return zip
    }

    func testSafeEntryNames() {
        XCTAssertTrue(WidgetArchive.isSafeEntryName("Clock.widget/index.jsx"))
        XCTAssertFalse(WidgetArchive.isSafeEntryName("../evil"))
        XCTAssertFalse(WidgetArchive.isSafeEntryName("a/../../evil"))
        XCTAssertFalse(WidgetArchive.isSafeEntryName("/etc/passwd"))
        XCTAssertFalse(WidgetArchive.isSafeEntryName("~/x"))
        XCTAssertFalse(WidgetArchive.isSafeEntryName(""))
    }

    func testSingleTopLevelFolderIsUnwrapped() throws {
        let zip = try makeZip(named: "ok.zip") { stage in
            let folder = stage.appendingPathComponent("Clock.widget")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "x".write(to: folder.appendingPathComponent("index.jsx"), atomically: true, encoding: .utf8)
        }
        let scratch = root.appendingPathComponent("out")
        let urls = try WidgetArchive().extract(zip, into: scratch)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Clock.widget"])
        XCTAssertNotNil(WidgetImporter.entryFile(in: urls[0]))
    }

    func testSymlinkInArchiveIsRejected() throws {
        let zip = try makeZip(named: "link.zip", populate: { stage in
            let folder = stage.appendingPathComponent("Bad.widget")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: folder.appendingPathComponent("index.jsx").path,
                withDestinationPath: "/etc/hosts"
            )
        }, extraArgs: ["-y"])
        let scratch = root.appendingPathComponent("out")
        XCTAssertThrowsError(try WidgetArchive().extract(zip, into: scratch)) { error in
            guard case WidgetArchive.ArchiveError.containsSymlink = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testEntryLimitIsEnforced() throws {
        let zip = try makeZip(named: "many.zip") { stage in
            for index in 0..<5 {
                try "x".write(to: stage.appendingPathComponent("f\(index).jsx"), atomically: true, encoding: .utf8)
            }
        }
        XCTAssertThrowsError(
            try WidgetArchive(maxEntries: 2).extract(zip, into: root.appendingPathComponent("out"))
        )
    }

    func testNotAZipFailsCleanly() throws {
        let bogus = root.appendingPathComponent("bogus.zip")
        try Data("nope".utf8).write(to: bogus)
        XCTAssertThrowsError(try WidgetArchive().extract(bogus, into: root.appendingPathComponent("out")))
    }

    func testRemoveWidgetRejectsTraversal() throws {
        let widgets = root.appendingPathComponent("widgets")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "x".write(to: outside.appendingPathComponent("index.jsx"), atomically: true, encoding: .utf8)

        XCTAssertNil(WidgetImporter(widgetDirectory: widgets).removeWidget(named: "../outside"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
