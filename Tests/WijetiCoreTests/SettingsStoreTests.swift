import XCTest
@testable import WijetiCore

final class SettingsStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SettingsStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uebersicht-settings-\(UUID().uuidString)")
        store = SettingsStore(url: directory.appendingPathComponent("WidgetSettings.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertTrue(store.load().isEmpty)
    }

    func testRoundTrip() throws {
        try store.save(["a": WidgetSettings(showOnAllScreens: true)])
        let loaded = SettingsStore(url: store.fileURL).load()
        XCTAssertEqual(loaded["a"]?.showOnAllScreens, true)
    }

    func testUpdateMergesAndPersists() throws {
        try store.save(["a": WidgetSettings(hidden: true)])
        let updated = try store.update("a") { $0.showOnMainScreen = true }

        XCTAssertTrue(updated.hidden)
        XCTAssertTrue(updated.showOnMainScreen)
        XCTAssertEqual(store.load()["a"], updated)
    }

    func testUpdateCreatesMissingEntry() throws {
        let created = try store.update("new") { $0.hidden = true }
        XCTAssertTrue(created.hidden)
        XCTAssertEqual(store.load().keys.sorted(), ["new"])
    }
}
