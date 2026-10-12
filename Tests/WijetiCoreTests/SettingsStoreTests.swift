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

final class SettingsStoreHardeningTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wijeti-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCorruptFileIsMovedAsideNotOverwritten() throws {
        let file = directory.appendingPathComponent("WidgetSettings.json")
        try Data("{ not json".utf8).write(to: file)
        let store = SettingsStore(url: file)

        XCTAssertTrue(store.load().isEmpty)
        try store.update("a") { $0.showOnAllScreens = true }

        let backup = file.appendingPathExtension("bak")
        XCTAssertEqual(try String(contentsOf: backup), "{ not json")
        XCTAssertEqual(store.load()["a"]?.showOnAllScreens, true)
    }

    func testConcurrentUpdatesDoNotLoseWrites() {
        let store = SettingsStore(url: directory.appendingPathComponent("WidgetSettings.json"))
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            try? store.update("widget-\(index)") { $0.showOnAllScreens = true }
        }
        XCTAssertEqual(store.load().count, 40)
    }
}

final class SettingsStoreUnknownKeyTests: XCTestCase {
    func testUnknownPerWidgetKeysSurviveASave() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wijeti-unknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("WidgetSettings.json")
        try Data(#"{"a":{"hidden":false,"futureFlag":"keep-me"}}"#.utf8).write(to: file)

        let store = SettingsStore(url: file)
        try store.update("a") { $0.hidden = true }

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]]
        XCTAssertEqual(raw?["a"]?["futureFlag"] as? String, "keep-me")
        XCTAssertEqual(raw?["a"]?["hidden"] as? Bool, true)
    }
}
