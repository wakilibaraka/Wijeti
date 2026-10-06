import XCTest
@testable import WijetiCore

final class PresetCatalogTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wijeti-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testDecodesCatalogEntries() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = """
        [{"id":"openmeteo-now","title":"Open-Meteo Now","category":"Weather",\
        "description":"Current conditions","entry":"index.jsx","source":"Wijeti"}]
        """
        try json.write(
            to: root.appendingPathComponent("Catalog.json"),
            atomically: true,
            encoding: .utf8
        )
        let catalog = PresetCatalog.load(from: root)
        XCTAssertEqual(catalog.presets.count, 1)
        XCTAssertEqual(catalog.presets.first?.id, "openmeteo-now")
        XCTAssertTrue(catalog.presets[0].isUsable)
    }

    func testUnusableEntriesAreHiddenFromTheLibrary() throws {
        let catalog = PresetCatalog(presets: [
            Preset(id: "ok", title: "Ok", category: "System", description: "", entry: "index.jsx", source: "s"),
            Preset(id: "broken", title: "Broken", category: "System", description: "", entry: "", source: "s"),
        ])
        XCTAssertEqual(catalog.groups.flatMap(\.presets).map(\.id), ["ok"])
    }

    func testGroupingPrefersKnownCategoryOrder() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("presets"), withIntermediateDirectories: true)
        let json = """
        [{"id":"a","title":"A","category":"Weather","description":"","entry":"index.jsx","source":"s"},
         {"id":"b","title":"B","category":"Zebra","description":"","entry":"index.jsx","source":"s"},
         {"id":"c","title":"C","category":"System","description":"","entry":"index.jsx","source":"s"}]
        """
        try json.write(
            to: root.appendingPathComponent("presets/Catalog.json"),
            atomically: true,
            encoding: .utf8
        )
        let catalog = PresetCatalog.load(from: root.appendingPathComponent("presets"))
        XCTAssertEqual(catalog.groups.map(\.category), ["Weather", "System", "Zebra"])
    }

    func testMalformedCatalogLoadsEmptyRatherThanCrashing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "not json".write(
            to: root.appendingPathComponent("Catalog.json"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(PresetCatalog.load(from: root).isEmpty)
    }
}

final class WidgetImporterTests: XCTestCase {
    private var root: URL!
    private var widgets: URL!
    private var incoming: URL!
    private var importer: WidgetImporter!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wijeti-import-\(UUID().uuidString)")
        widgets = root.appendingPathComponent("widgets")
        incoming = root.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        importer = WidgetImporter(widgetDirectory: widgets)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Mirrors `server/src/resolveWidget.js`: path relative to the root, split on `/` with
    /// empty parts dropped, `.` becomes `-`, whitespace becomes `_`.
    func testWidgetIDMatchesServerDerivation() {
        let file = widgets.appendingPathComponent("liquid-glass-calendar.widget/index.jsx")
        XCTAssertEqual(
            WidgetImporter.widgetID(for: file, root: widgets),
            "liquid-glass-calendar-widget-index-jsx"
        )
        let bare = widgets.appendingPathComponent("GettingStarted.jsx")
        XCTAssertEqual(WidgetImporter.widgetID(for: bare, root: widgets), "GettingStarted-jsx")
        let spaced = widgets.appendingPathComponent("My Widget.widget/index.coffee")
        XCTAssertEqual(WidgetImporter.widgetID(for: spaced, root: widgets), "My_Widget-widget-index-coffee")
    }

    func testImportsWidgetFolder() throws {
        let source = incoming.appendingPathComponent("Clock.widget")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "x".write(to: source.appendingPathComponent("index.coffee"), atomically: true, encoding: .utf8)

        XCTAssertTrue(importer.canImport(source))
        let result = try importer.importWidgets(at: [source])
        XCTAssertEqual(result.installed, ["Clock-widget"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: widgets.appendingPathComponent("Clock.widget/index.coffee").path)
        )
    }

    func testBareWidgetFileBecomesItsOwnFolder() throws {
        let source = incoming.appendingPathComponent("clock.jsx")
        try "x".write(to: source, atomically: true, encoding: .utf8)

        let result = try importer.importWidgets(at: [source])
        XCTAssertEqual(result.installed, ["clock-jsx"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: widgets.appendingPathComponent("clock.jsx/clock.jsx").path
            )
        )
    }

    func testSkipsRatherThanOverwritesExistingWidget() throws {
        let source = incoming.appendingPathComponent("Clock.widget")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "new".write(to: source.appendingPathComponent("index.coffee"), atomically: true, encoding: .utf8)
        _ = try importer.importWidgets(at: [source])

        // A second import of a different build of the same widget must not clobber edits.
        let edited = root.appendingPathComponent("edited/Clock.widget")
        try FileManager.default.createDirectory(at: edited, withIntermediateDirectories: true)
        try "edited".write(to: edited.appendingPathComponent("index.coffee"), atomically: true, encoding: .utf8)

        let result = try importer.importWidgets(at: [edited])
        XCTAssertTrue(result.installed.isEmpty)
        XCTAssertEqual(result.skipped, ["Clock.widget"])
        let installed = try String(contentsOf: widgets.appendingPathComponent("Clock.widget/index.coffee"))
        XCTAssertEqual(installed, "new")
    }

    func testRejectsFolderWithoutAnEntryFile() throws {
        let source = incoming.appendingPathComponent("NotAWidget")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "readme".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        XCTAssertFalse(importer.canImport(source))
        let result = try importer.importWidgets(at: [source])
        XCTAssertTrue(result.installed.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].reason.contains("index.jsx"))
    }

    func testRemoveReportsTheIDTheServerWillDrop() throws {
        let source = incoming.appendingPathComponent("Top.widget")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "x".write(to: source.appendingPathComponent("index.coffee"), atomically: true, encoding: .utf8)
        _ = try importer.importWidgets(at: [source])

        XCTAssertEqual(importer.removeWidget(named: "Top.widget"), "Top-widget")
        XCTAssertNil(importer.removeWidget(named: "Top.widget"))
    }
}
