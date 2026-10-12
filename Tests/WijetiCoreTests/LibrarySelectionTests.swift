import XCTest
@testable import WijetiCore

final class LibrarySelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testToggleAddsAndRemoves() {
        var selection = LibrarySelection()
        selection.toggle("b")
        selection.toggle("d")
        XCTAssertEqual(selection.keys, ["b", "d"])
        selection.toggle("b")
        XCTAssertEqual(selection.keys, ["d"])
    }

    func testSelectOnlyReplaces() {
        var selection = LibrarySelection()
        selection.toggle("a")
        selection.select(only: "c")
        XCTAssertEqual(selection.keys, ["c"])
    }

    func testRangeSelectsBetweenAnchorAndTarget() {
        var selection = LibrarySelection()
        selection.select(only: "b")
        selection.extend(to: "d", in: order)
        XCTAssertEqual(selection.keys, ["b", "c", "d"])
    }

    func testRangeWorksBackwards() {
        var selection = LibrarySelection()
        selection.select(only: "d")
        selection.extend(to: "a", in: order)
        XCTAssertEqual(selection.keys, ["a", "b", "c", "d"])
    }

    func testRangeWithoutAnchorToggles() {
        var selection = LibrarySelection()
        selection.extend(to: "c", in: order)
        XCTAssertEqual(selection.keys, ["c"])
    }

    func testSelectAllAndClear() {
        var selection = LibrarySelection()
        selection.selectAll(order)
        XCTAssertEqual(selection.count, 5)
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    func testRetainDropsRemovedItems() {
        var selection = LibrarySelection()
        selection.selectAll(order)
        selection.retain(only: ["a", "b"])
        XCTAssertEqual(selection.keys, ["a", "b"])
        XCTAssertNil(selection.anchor)
    }
}
