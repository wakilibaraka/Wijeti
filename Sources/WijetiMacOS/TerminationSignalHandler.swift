import Foundation
import WijetiCore

/// Turns SIGTERM/SIGINT into a bounded, orderly quit.
///
/// The old handler was `signal(SIGTERM) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }`:
/// a signal only *asked* the main thread to quit, so a main thread blocked in a web-view load,
/// a modal panel or a deadlock ignored the request and the app kept its widget servers
/// running. This handler does the part that must not wait — mark the process as quitting and
/// kill the children — on its own queue, then asks AppKit to quit and exits itself if AppKit
/// does not. A signal never depends on the main thread again.
public final class TerminationSignalHandler {
    private let queue = DispatchQueue(label: "app.wijeti.termination")
    private var sources: [DispatchSourceSignal] = []
    private let grace: TimeInterval
    private let requestQuit: () -> Void
    private let forceExit: (Int32) -> Void
    /// Only touched on `queue`, which is also where the sources deliver.
    private var handled = false

    /// - Parameter grace: how long AppKit gets to finish quitting before the process exits.
    ///   The children are already gone by then; this only covers a wedged main thread.
    public init(
        grace: TimeInterval = 4,
        requestQuit: @escaping () -> Void,
        forceExit: @escaping (Int32) -> Void = { _ in _exit(0) }
    ) {
        self.grace = grace
        self.requestQuit = requestQuit
        self.forceExit = forceExit
    }

    /// Installs the handlers. Call once, before the app starts running or quitting.
    public func start() {
        for sig in [SIGTERM, SIGINT] {
            // A dispatch source only delivers a signal the process is ignoring; otherwise the
            // default action races the source and usually wins.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.received(sig) }
            source.resume()
            sources.append(source)
        }
    }

    private func received(_ sig: Int32) {
        guard !handled else { return }
        handled = true
        NSLog("received signal %d; quitting", sig)

        // Before the kills: a supervisor that reads its child's exit as a crash must find
        // the process already quitting, or it schedules a replacement.
        ProcessTermination.begin()
        ChildProcessRegistry.shared.terminateAll()

        DispatchQueue.main.async { [requestQuit] in
            requestQuit()
        }

        queue.asyncAfter(deadline: .now() + grace) { [grace, forceExit] in
            NSLog("Wijeti did not finish quitting in %.1f s; exiting anyway", grace)
            // Nothing may outlive the app: a quit that skipped `applicationWillTerminate`
            // still leaves no server holding the ports.
            ChildProcessRegistry.shared.terminateAll(grace: 0)
            forceExit(sig)
        }
    }
}
