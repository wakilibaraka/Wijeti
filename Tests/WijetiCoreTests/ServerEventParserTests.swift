import XCTest
@testable import WijetiCore

final class ServerEventParserTests: XCTestCase {
    func testParsesStartedLine() {
        var parser = ServerEventParser()
        XCTAssertEqual(parser.consume("server started on port 41416\n"), [.started])
    }

    func testParsesAddressInUse() {
        var parser = ServerEventParser()
        XCTAssertEqual(parser.consume("Error: listen EADDRINUSE: address already in use\n"), [.addressInUse])
    }

    func testSignalSplitAcrossReadsIsNotMissed() {
        var parser = ServerEventParser()
        XCTAssertEqual(parser.consume("server star"), [])
        XCTAssertEqual(parser.consume("ted on port 41416\n"), [.started])
    }

    func testSeveralLinesInOneChunk() {
        var parser = ServerEventParser()
        let events = parser.consume("watching /widgets\nserver started on port 41416\nCORS Anywhere on 41417\n")
        XCTAssertEqual(events, [.started])
    }

    func testFlushEmitsTrailingLineWithoutNewline() {
        var parser = ServerEventParser()
        XCTAssertEqual(parser.consume("server started on port 41416"), [])
        XCTAssertEqual(parser.flush(), [.started])
        XCTAssertEqual(parser.flush(), [])
    }

    func testIgnoresUnrelatedOutput() {
        var parser = ServerEventParser()
        XCTAssertEqual(parser.consume("watching /some/path\n"), [])
    }
}
