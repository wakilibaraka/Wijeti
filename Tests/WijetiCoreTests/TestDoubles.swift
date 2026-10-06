import Foundation
@testable import WijetiCore

/// Stands in for the spawned Node process so supervisor behaviour can be driven
/// deterministically from a test.
final class FakeServerHandle: ServerProcessHandle {
    var onOutput: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?
    var isRunning = true
    var didTerminate = false

    func emit(_ text: String) { onOutput?(Data(text.utf8)) }
    func exit(status: Int32 = 1) {
        isRunning = false
        onTermination?(status)
    }
    func terminate() {
        didTerminate = true
        isRunning = false
    }
}

final class FakeLauncher: ServerProcessLaunching {
    private(set) var requests: [ServerLaunchRequest] = []
    private(set) var handles: [FakeServerHandle] = []
    var errorToThrow: Error?

    func launch(_ request: ServerLaunchRequest) throws -> ServerProcessHandle {
        if let errorToThrow { throw errorToThrow }
        requests.append(request)
        let handle = FakeServerHandle()
        handles.append(handle)
        return handle
    }

    var lastRequest: ServerLaunchRequest? { requests.last }
    var lastHandle: FakeServerHandle? { handles.last }
    var portsAttempted: [String] {
        requests.compactMap { request in
            guard let index = request.arguments.firstIndex(of: "-p"),
                  index + 1 < request.arguments.count
            else { return nil }
            return request.arguments[index + 1]
        }
    }
}
