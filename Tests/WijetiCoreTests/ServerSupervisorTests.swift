import XCTest
@testable import WijetiCore

final class ServerSupervisorTests: XCTestCase {
    private var launcher: FakeLauncher!
    private var scheduled: [() -> Void] = []
    private var log: [String] = []
    private var supervisor: ServerSupervisor!

    private func makeSupervisor(maxPortOffset: Int = 20) -> ServerSupervisor {
        let executable = URL(fileURLWithPath: "/tmp/localnode")
        return ServerSupervisor(
            basePort: 41416,
            executable: executable,
            argumentsForPort: { ["server.js", "-p", String($0)] },
            launcher: launcher,
            maxPortOffset: maxPortOffset,
            restartDelay: 1.0,
            scheduler: { [weak self] _, block in self?.scheduled.append(block) },
            log: { [weak self] message in self?.log.append(message) }
        )
    }

    override func setUp() {
        super.setUp()
        launcher = FakeLauncher()
        scheduled = []
        log = []
        supervisor = makeSupervisor()
    }

    func testStartPassesExpectedArguments() {
        XCTAssertTrue(supervisor.start())
        XCTAssertEqual(launcher.lastRequest?.executable.path, "/tmp/localnode")
        XCTAssertEqual(launcher.lastRequest?.arguments, ["server.js", "-p", "41416"])
        XCTAssertTrue(supervisor.isRunning)
    }

    /// Fires the callbacks the supervisor handed to the injected scheduler, which is how
    /// the restart delay is advanced without sleeping.
    private func runPendingRestarts() {
        let pending = scheduled
        scheduled.removeAll()
        pending.forEach { $0() }
    }

    func testStartReportedToDelegate() {
        var startedPorts: [Int] = []
        supervisor.onServerStarted = { startedPorts.append($0) }
        supervisor.start()

        launcher.lastHandle?.emit("watching /widgets\nserver started on port 41416\n")

        XCTAssertEqual(startedPorts, [41416])
    }

    func testAddressInUseMovesToNextPortOnRestart() {
        supervisor.start()
        launcher.lastHandle?.emit("Error: listen EADDRINUSE: address already in use\n")
        launcher.lastHandle?.exit()

        XCTAssertEqual(scheduled.count, 1, "an unexpected exit must schedule exactly one restart")
        runPendingRestarts()

        XCTAssertEqual(launcher.portsAttempted, ["41416", "41417"])
        XCTAssertEqual(supervisor.port, 41417)
        XCTAssertFalse(supervisor.gaveUp)
    }

    func testRepeatedAddressInUseFromOneProcessCountsOnce() {
        supervisor.start()
        // The real server prints the same bind failure on several lines.
        launcher.lastHandle?.emit("""
        Error: listen EADDRINUSE: address already in use 127.0.0.1:41416
            at Server.setupListenHandle
        Error: listen EADDRINUSE: address already in use 127.0.0.1:41416
        Error: listen EADDRINUSE: address already in use 127.0.0.1:41416
        """)
        launcher.lastHandle?.exit()
        runPendingRestarts()

        XCTAssertEqual(launcher.portsAttempted, ["41416", "41417"], "one collision must cost one port")
        XCTAssertEqual(log.filter { $0.contains("in use") }.count, 1)
    }

    func testPortOffsetResetsAfterSuccessfulStart() {
        supervisor.start()
        launcher.lastHandle?.emit("EADDRINUSE\n")
        launcher.lastHandle?.exit()
        runPendingRestarts()
        launcher.lastHandle?.emit("server started on port 41417\n")
        XCTAssertEqual(supervisor.portOffset, 0)

        launcher.lastHandle?.exit()
        runPendingRestarts()

        XCTAssertEqual(launcher.portsAttempted.last, "41416")
    }

    func testGivesUpAfterExhaustingPorts() {
        supervisor = makeSupervisor(maxPortOffset: 2)
        var stops = 0
        supervisor.onServerStopped = { stops += 1 }

        supervisor.start()
        for _ in 0..<5 {
            launcher.lastHandle?.emit("EADDRINUSE\n")
            launcher.lastHandle?.exit()
            if scheduled.isEmpty { break }
            runPendingRestarts()
        }

        // Two ports are tried, then the supervisor gives up rather than walking further.
        XCTAssertEqual(launcher.portsAttempted, ["41416", "41417"])
        XCTAssertTrue(scheduled.isEmpty, "supervisor should stop rescheduling once ports run out")
        XCTAssertTrue(supervisor.gaveUp)
        XCTAssertGreaterThan(stops, 0)
        XCTAssertTrue(log.contains { $0.contains("couldn't find an open port") })
    }

    func testStopPreventsRestart() {
        supervisor.start()
        supervisor.stop()
        XCTAssertFalse(supervisor.isRunning)
        XCTAssertTrue(launcher.lastHandle?.didTerminate == true)

        // The exit callback the OS delivers after terminate must not schedule a restart.
        launcher.lastHandle?.onTermination?(0)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testStartIsIdempotentWhileRunning() {
        XCTAssertTrue(supervisor.start())
        XCTAssertFalse(supervisor.start())
        XCTAssertEqual(launcher.requests.count, 1)
    }

    func testLaunchFailureIsRetried() {
        launcher.errorToThrow = NSError(domain: "test", code: 1)
        XCTAssertFalse(supervisor.start())
        XCTAssertEqual(scheduled.count, 1, "a failed launch must still schedule a retry")

        launcher.errorToThrow = nil
        runPendingRestarts()

        XCTAssertTrue(supervisor.isRunning)
        XCTAssertEqual(launcher.portsAttempted, ["41416"], "a failed launch retries the same port")
    }
}

final class ServerSupervisorResilienceTests: XCTestCase {
    private var launcher: FakeLauncher!
    private var delays: [TimeInterval] = []
    private var scheduled: [() -> Void] = []

    private func make() -> ServerSupervisor {
        ServerSupervisor(
            basePort: 41416,
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            argumentsForPort: { ["-p", String($0)] },
            launcher: launcher,
            restartDelay: 1.0,
            scheduler: { [weak self] delay, block in
                self?.delays.append(delay)
                self?.scheduled.append(block)
            },
            log: { _ in }
        )
    }

    private func fireRestart() {
        let pending = scheduled
        scheduled.removeAll()
        pending.forEach { $0() }
    }

    override func setUp() {
        launcher = FakeLauncher()
        delays = []
        scheduled = []
    }

    func testCrashLoopBacksOffExponentially() {
        let supervisor = make()
        supervisor.start()
        for _ in 0..<4 {
            launcher.lastHandle?.exit()
            fireRestart()
        }
        XCTAssertEqual(delays, [1, 2, 4, 8])
    }

    func testCrashLoopEventuallyGivesUp() {
        let supervisor = make()
        supervisor.start()
        for _ in 0..<ServerSupervisor.maxConsecutiveFailures {
            launcher.lastHandle?.exit()
            fireRestart()
        }
        XCTAssertTrue(supervisor.gaveUp)
    }

    func testSuccessfulStartResetsBackoff() {
        let supervisor = make()
        supervisor.start()
        launcher.lastHandle?.exit()
        fireRestart()
        launcher.lastHandle?.emit("server started on port 41416\n")
        launcher.lastHandle?.exit()
        fireRestart()
        XCTAssertEqual(delays, [1, 1])
    }

    func testStaleTerminationDoesNotAffectNewProcess() {
        let supervisor = make()
        supervisor.start()
        let old = launcher.lastHandle!
        supervisor.stop()
        XCTAssertTrue(supervisor.start())
        old.exit()
        XCTAssertTrue(supervisor.isRunning)
        XCTAssertFalse(supervisor.restartScheduled)
        XCTAssertEqual(launcher.handles.count, 2)
    }
}
