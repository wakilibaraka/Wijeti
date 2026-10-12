import XCTest
@testable import WijetiCore

final class UserWidgetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wijeti-userwidgets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStoreRoundTripAndRemove() throws {
        let store = UserWidgetStore(url: root.appendingPathComponent("UserWidgets.json"))
        XCTAssertTrue(store.load().isEmpty)
        try store.set(UserWidgetMeta(title: "My Clock", category: "Clock"), for: "clock.widget")
        XCTAssertEqual(store.load()["clock.widget"]?.title, "My Clock")
        try store.remove(folder: "clock.widget")
        XCTAssertTrue(store.load().isEmpty)
    }

    func testDefaultTitles() {
        XCTAssertEqual(UserWidgetStore.defaultTitle(forFolder: "my-cool_clock.widget"), "My Cool Clock")
        XCTAssertEqual(UserWidgetStore.defaultTitle(forFolder: "weather.jsx"), "Weather")
    }

    func testHTMLFileIsWrappedAsWidget() throws {
        let html = root.appendingPathComponent("hello.html")
        try "<h1 class=\"x\">Hi \"there\"</h1><script>1</script>".write(to: html, atomically: true, encoding: .utf8)
        let widgets = root.appendingPathComponent("widgets")
        let importer = WidgetImporter(widgetDirectory: widgets)

        XCTAssertTrue(importer.canImport(html))
        let result = try importer.importWidgets(at: [html])

        XCTAssertEqual(result.installedFolders, ["hello.widget"])
        let source = try String(contentsOf: widgets.appendingPathComponent("hello.widget/index.jsx"))
        XCTAssertTrue(source.contains("export const render"))
        XCTAssertTrue(source.contains("srcDoc={page}"))
        // The page is embedded as a JSON string, so its quotes are escaped.
        XCTAssertTrue(source.contains("\\\"there\\\""))
        XCTAssertNotNil(WidgetImporter.entryFile(in: widgets.appendingPathComponent("hello.widget")))
    }

    func testImportReportsInstalledFolder() throws {
        let file = root.appendingPathComponent("clock.jsx")
        try "export const render = () => null".write(to: file, atomically: true, encoding: .utf8)
        let result = try WidgetImporter(widgetDirectory: root.appendingPathComponent("w")).importWidgets(at: [file])
        XCTAssertEqual(result.installedFolders, ["clock.jsx"])
    }
}
