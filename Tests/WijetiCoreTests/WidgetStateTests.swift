import XCTest
@testable import WijetiCore

final class WidgetStateTests: XCTestCase {
    /// Captured verbatim from the running widget server on this machine.
    let realPayload = """
    {"widgets":{"GettingStarted-jsx":{"id":"GettingStarted-jsx",\
    "filePath":"/Users/baraka/Library/Application Support/Übersicht/widgets/GettingStarted.jsx",\
    "mtime":"2026-10-05T22:12:02.305Z"}},\
    "settings":{"GettingStarted-jsx":{"showOnAllScreens":true,"showOnMainScreen":false,\
    "showOnSelectedScreens":false,"hidden":false,"screens":[]}},"screens":[1]}
    """

    func testDecodesRealServerPayload() throws {
        let state = try JSONDecoder().decode(WidgetStateResponse.self, from: Data(realPayload.utf8))

        XCTAssertEqual(state.screens, [1])
        XCTAssertEqual(state.widgets.count, 1)
        let widget = try XCTUnwrap(state.widgets["GettingStarted-jsx"])
        XCTAssertEqual(widget.id, "GettingStarted-jsx")
        XCTAssertTrue(widget.filePath.hasSuffix("GettingStarted.jsx"))

        let settings = state.settings(for: "GettingStarted-jsx")
        XCTAssertTrue(settings.showOnAllScreens)
        XCTAssertFalse(settings.hidden)
    }

    func testPartialPayloadUsesDefaults() throws {
        let state = try JSONDecoder().decode(
            WidgetStateResponse.self,
            from: Data(#"{"widgets":{}}"#.utf8)
        )
        XCTAssertTrue(state.screens.isEmpty)
        XCTAssertEqual(state.settings(for: "missing"), WidgetSettings())
    }

    func testVisibilityRules() {
        let all = WidgetSettings(showOnAllScreens: true)
        XCTAssertTrue(all.isVisible(onScreen: 1))
        XCTAssertTrue(all.isVisible(onScreen: 2))

        let mainOnly = WidgetSettings(showOnAllScreens: false, showOnMainScreen: true)
        XCTAssertTrue(mainOnly.isVisible(onScreen: 1))
        XCTAssertFalse(mainOnly.isVisible(onScreen: 2))

        let selected = WidgetSettings(
            showOnAllScreens: false,
            showOnSelectedScreens: true,
            screens: [2]
        )
        XCTAssertFalse(selected.isVisible(onScreen: 1))
        XCTAssertTrue(selected.isVisible(onScreen: 2))

        let hidden = WidgetSettings(hidden: true)
        XCTAssertFalse(hidden.isVisible(onScreen: 1))

        // Default: visible everywhere.
        XCTAssertTrue(WidgetSettings().isVisible(onScreen: 1))
        XCTAssertTrue(WidgetSettings().isVisible(onScreen: 3))
    }

    /// Regression: these defaults must equal `defaultSettings` in `server/src/reducer.js`.
    /// With `showOnAllScreens` defaulting to false, writing any setting made every widget
    /// invisible on every screen, because `render.js` only shows widgets that match one of
    /// the three screen flags.
    func testDefaultsMatchTheServer() {
        let decoded = try! JSONDecoder().decode(
            WidgetSettings.self,
            from: Data(#"{}"#.utf8)
        )
        XCTAssertEqual(decoded, WidgetSettings())
        XCTAssertTrue(decoded.showOnAllScreens, "server default is showOnAllScreens: true")
        XCTAssertFalse(decoded.showOnMainScreen)
        XCTAssertFalse(decoded.showOnSelectedScreens)
        XCTAssertFalse(decoded.hidden)
        XCTAssertTrue(decoded.screens.isEmpty)
        XCTAssertFalse(decoded.inBackground)
        XCTAssertTrue(decoded.isVisible(onScreen: 1))

        // …and no combination of the three screen flags may fall through to invisible.
        XCTAssertFalse(
            WidgetSettings(showOnAllScreens: false).isVisible(onScreen: 1),
            "matches render.js: no flag matches ⇒ not visible"
        )
    }
}
