import Foundation

public struct ServerLaunchRequest: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// A running widget-server child process. Abstracted so the supervisor can be tested
/// without spawning Node.
public protocol ServerProcessHandle: AnyObject {
    var onOutput: ((Data) -> Void)? { get set }
    var onTermination: ((Int32) -> Void)? { get set }
    var isRunning: Bool { get }
    func terminate()
}

public protocol ServerProcessLaunching: AnyObject {
    func launch(_ request: ServerLaunchRequest) throws -> ServerProcessHandle
}

/// Owns the lifetime of the bundled Node widget server.
///
/// Behaviour follows `-[UBAppDelegate startUp]` / `handleExit:`: start the server, walk
/// the port forward on `EADDRINUSE`, restart a second after an unexpected exit, and give
/// up once the offset runs out. One deliberate difference: the offset resets after a
/// successful start, so a port freed later is reused instead of the app drifting upwards
/// for the rest of the session.
public final class ServerSupervisor {
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
    public typealias Log = (String) -> Void

    /// Consecutive launches that died without ever reporting `started` before the supervisor
    /// stops retrying. Each failure doubles the restart delay, up to `maxRestartDelay`.
    public static let maxConsecutiveFailures = 8
    public static let maxRestartDelay: TimeInterval = 30

    public private(set) var port: Int
    public private(set) var portOffset: Int = 0
    public private(set) var isRunning: Bool = false
    public private(set) var restartScheduled: Bool = false

    /// True once the port offset has been exhausted and the supervisor stopped retrying.
    public private(set) var gaveUp: Bool = false

    public var onServerStarted: ((Int) -> Void)?
    public var onServerStopped: (() -> Void)?

    private let basePort: Int
    private let executable: URL
    private let argumentsForPort: (Int) -> [String]
    private let launcher: ServerProcessLaunching
    private let maxPortOffset: Int
    private let restartDelay: TimeInterval
    private let scheduler: Scheduler
    private let log: Log
    private var parser = ServerEventParser()
    private var handle: ServerProcessHandle?
    private var shuttingDown = false
    /// Bumped on every launch. A termination callback carries the generation of the process
    /// it belongs to, so a late callback from a replaced process cannot tear down its successor.
    private var generation = 0
    private var consecutiveFailures = 0
    private var didStartThisLaunch = false
    public private(set) var nextRestartDelay: TimeInterval = 0
    /// The widget server reports one bind failure several times over: `server.coffee`
    /// logs the error and then rethrows it, so the same `EADDRINUSE` arrives on multiple
    /// lines. The offset must advance once per launch, not once per line.
    private var handledAddressInUse = false

    public init(
        basePort: Int,
        executable: URL,
        argumentsForPort: @escaping (Int) -> [String],
        launcher: ServerProcessLaunching,
        maxPortOffset: Int = 20,
        restartDelay: TimeInterval = 1.0,
        scheduler: @escaping Scheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        },
        log: @escaping Log = { NSLog("%@", $0) }
    ) {
        self.basePort = basePort
        self.port = basePort
        self.executable = executable
        self.argumentsForPort = argumentsForPort
        self.launcher = launcher
        self.maxPortOffset = maxPortOffset
        self.restartDelay = restartDelay
        self.scheduler = scheduler
        self.log = log
    }

    @discardableResult
    public func start() -> Bool {
        guard !isRunning, !restartScheduled else { return false }
        shuttingDown = false
        gaveUp = false
        handledAddressInUse = false
        didStartThisLaunch = false
        parser = ServerEventParser()
        port = basePort + portOffset
        generation += 1
        let launchGeneration = generation
        do {
            let handle = try launcher.launch(
                ServerLaunchRequest(executable: executable, arguments: argumentsForPort(port))
            )
            self.handle = handle
            isRunning = true
            log("launching widget server on port \(port): \(executable.lastPathComponent)")

            handle.onOutput = { [weak self] data in
                guard let self else { return }
                for event in self.parser.consume(data) {
                    self.handle(event)
                }
            }
            handle.onTermination = { [weak self] _ in
                guard let self, self.generation == launchGeneration else { return }
                self.parser.flush().forEach { self.handle($0) }
                self.handleTermination()
            }
            return true
        } catch {
            log("failed to launch widget server: \(error)")
            handleTermination()
            return false
        }
    }

    /// Restarts the server in place: the exit handler schedules the replacement process,
    /// so the port walk and restart delay behave exactly as they do after a crash.
    public func restart() {
        guard !shuttingDown else { return }
        guard isRunning, let handle else {
            _ = start()
            return
        }
        log("restarting widget server")
        handle.terminate()
    }

    public func stop() {
        shuttingDown = true
        restartScheduled = false
        generation += 1
        if let handle {
            handle.terminate()
        }
        isRunning = false
        self.handle = nil
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .started:
            log("server started on port \(port)")
            portOffset = 0
            didStartThisLaunch = true
            consecutiveFailures = 0
            onServerStarted?(port)
        case .addressInUse:
            guard !handledAddressInUse else { return }
            handledAddressInUse = true
            log("port \(port) in use, trying \(port + 1)")
            portOffset = min(portOffset + 1, maxPortOffset)
        }
    }

    private func handleTermination() {
        isRunning = false
        handle = nil
        guard !shuttingDown else { return }

        onServerStopped?()

        if portOffset >= maxPortOffset {
            gaveUp = true
            log("couldn't find an open port. Giving up...")
            return
        }

        if didStartThisLaunch {
            consecutiveFailures = 0
        } else if !handledAddressInUse {
            // A launch that died without a port clash and without ever starting is a crash.
            consecutiveFailures += 1
            if consecutiveFailures >= Self.maxConsecutiveFailures {
                gaveUp = true
                log("widget server keeps crashing on launch. Giving up...")
                return
            }
        }
        let exponent = max(0, consecutiveFailures - 1)
        nextRestartDelay = min(restartDelay * pow(2, Double(exponent)), Self.maxRestartDelay)
        restartScheduled = true
        scheduler(nextRestartDelay) { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.restartScheduled = false
            _ = self.start()
        }
    }
}
