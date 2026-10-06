import Foundation
import WijetiCore

/// Wraps Foundation's `Process` — the Swift equivalent of the `NSTask` that
/// `-[UBAppDelegate launchWidgetServer:onData:onExit:]` built by hand.
///
/// `localnode` is a `/bin/zsh` script, and Foundation launches shebang scripts through the
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
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.onOutput?(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.onOutput?(data) }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.onTermination?(finished.terminationStatus) }
        }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
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
        return handle
    }
}
