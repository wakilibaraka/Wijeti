import Foundation
import WijetiCore

/// Wraps Foundation's `Process` — the Swift equivalent of the `NSTask` that
/// `-[UBAppDelegate launchWidgetServer:onData:onExit:]` built by hand.
///
/// `localnode` is a shell script, and Foundation launches shebang scripts through the
/// interpreter, so the supervisor can keep spawning `localnode` rather than picking the
/// architecture-specific `node` binary itself.
final class AppKitProcessHandle: ServerProcessHandle {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    var onOutput: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?

    var isRunning: Bool { process.isRunning }

    init() {
        Self.forward(stdoutPipe, to: self)
        Self.forward(stderrPipe, to: self)
        process.terminationHandler = { [weak self] finished in
            ChildProcessRegistry.shared.unregister(finished.processIdentifier)
            DispatchQueue.main.async { self?.onTermination?(finished.terminationStatus) }
        }
    }

    /// SIGTERM, then SIGKILL if the child ignores it: a hung node would otherwise keep the
    /// port bound and leave `restart()` waiting forever.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        // Escalate off the main queue: quitting is exactly when the main thread can be busy,
        // and an escalation scheduled there would never run — leaving the server and its
        // ports behind after the app exits. `self` is held strongly for the grace period so
        // a supervisor that drops its handle right after `terminate()` still escalates.
        Self.escalationQueue.asyncAfter(deadline: .now() + Self.killGrace) { [self] in
            guard process.isRunning else { return }
            NSLog("widget server ignored SIGTERM; sending SIGKILL")
            kill(pid, SIGKILL)
        }
    }

    private static let killGrace: TimeInterval = 3
    private static let escalationQueue = DispatchQueue(
        label: "app.wijeti.server-terminate",
        qos: .userInitiated
    )

    /// Pumps a pipe into `onOutput` one complete line at a time and detaches at EOF.
    ///
    /// The `else { return }` that used to guard empty data was a CPU bug, not a no-op: once
    /// the child closes the pipe, `availableData` returns empty immediately *every* time it is
    /// asked, and a still-installed `readabilityHandler` keeps being scheduled — spinning a
    /// core at 100% for the rest of the session. Detaching the handler is what ends it.
    ///
    /// stdout and stderr feed one parser, so each pipe buffers its own partial line here;
    /// otherwise chunks from the two streams could interleave mid-line and corrupt an event.
    private static func forward(_ pipe: Pipe, to handle: AppKitProcessHandle) {
        var partial = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak handle] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                if !partial.isEmpty {
                    let rest = partial + Data([0x0A])
                    partial = Data()
                    DispatchQueue.main.async { handle?.onOutput?(rest) }
                }
                return
            }
            partial.append(data)
            guard let newline = partial.lastIndex(of: 0x0A) else { return }
            let complete = partial[partial.startIndex...newline]
            partial = Data(partial[partial.index(after: newline)...])
            let chunk = Data(complete)
            DispatchQueue.main.async { handle?.onOutput?(chunk) }
        }
    }
}

public final class AppKitProcessLauncher: ServerProcessLaunching {
    public init() {}

    public func launch(_ request: ServerLaunchRequest) throws -> ServerProcessHandle {
        let handle = AppKitProcessHandle()
        handle.process.executableURL = request.executable
        handle.process.arguments = request.arguments
        handle.process.standardOutput = handle.stdoutPipe
        handle.process.standardError = handle.stderrPipe
        try handle.process.run()
        // From here on a quit must be able to kill this child even if the main thread never
        // runs another block (see `ChildProcessRegistry`).
        ChildProcessRegistry.shared.register(handle.process.processIdentifier)
        return handle
    }
}
