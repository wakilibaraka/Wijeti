import Foundation

/// Process-wide "we are quitting" state.
///
/// The supervisor decides on its own to launch a replacement when its child exits. That is
/// right after a crash and wrong during quit: the quit path terminates the child first, the
/// supervisor reads the exit as a crash, schedules a restart, and an app that was asked to
/// quit keeps a fresh server alive. That is how an instance survived SIGTERM and kept
/// respawning its preview server on 41516/41517.
///
/// The flag is set *before* anything is signalled, from whichever thread caught the signal,
/// so no restart can be scheduled even while the main thread is wedged.
public enum ProcessTermination {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var terminating = false

    public static var isTerminating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminating
    }

    /// Marks the process as quitting. Idempotent, and safe from any thread.
    public static func begin() {
        lock.lock()
        terminating = true
        lock.unlock()
    }

    /// Test hook: leaves the process-wide flag clean between cases.
    public static func reset() {
        lock.lock()
        terminating = false
        lock.unlock()
    }
}

/// Child PIDs the app has to reap on the way out.
///
/// A supervisor already terminates its own child, but that kill escalates on the main queue —
/// exactly what is unavailable when the main thread is the reason quitting is stuck. Keeping
/// the PIDs here lets the signal path kill them from its own queue instead, without asking
/// AppKit for anything.
public final class ChildProcessRegistry: @unchecked Sendable {
    public static let shared = ChildProcessRegistry()

    /// How long a child gets to act on SIGTERM before SIGKILL follows.
    public static let grace: TimeInterval = 0.25

    private let lock = NSLock()
    private var pids: Set<Int32> = []

    public init() {}

    public func register(_ pid: Int32) {
        guard pid > 0 else { return }
        lock.lock()
        pids.insert(pid)
        lock.unlock()
    }

    public func unregister(_ pid: Int32) {
        lock.lock()
        pids.remove(pid)
        lock.unlock()
    }

    public var registeredPIDs: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return pids.sorted()
    }

    /// SIGTERM every registered child, then SIGKILL whatever survives a short grace.
    ///
    /// Deliberately synchronous and bounded: the caller is usually the quit path, and a fixed
    /// wait is what makes the app's exit independent of AppKit. The escalation does not test
    /// liveness first — an already-exited child answers ESRCH, and a zombie answers 0, so a
    /// liveness check would turn a fast quit into a full grace period every time.
    public func terminateAll(grace: TimeInterval = ChildProcessRegistry.grace) {
        let targets = registeredPIDs
        guard !targets.isEmpty else { return }
        for pid in targets {
            kill(pid, SIGTERM)
        }
        if grace > 0 {
            Thread.sleep(forTimeInterval: grace)
        }
        for pid in targets {
            kill(pid, SIGKILL)
        }
        lock.lock()
        pids.subtract(targets)
        lock.unlock()
    }
}
