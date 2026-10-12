import Foundation

/// The host's own connection to the widget server's message bus.
///
/// The server relays any JSON a client sends to every other client (`MessageBus`), and it
/// only accepts connections whose `Origin` is the widget origin or the literal `Übersicht`
/// string the original host sent. This is how the tray menu's Refresh, the preferences
/// toggles and AppleScript property writes reach every open widget without reloading a
/// page — the same mechanism as `UBWebSocket` plus `dispatch.js`.
///
/// All state is touched on the main queue only; URLSession callbacks hop there first. Each
/// connection carries a generation number so a late failure from a cancelled task cannot
/// tear down (or double up) its replacement.
public final class HostSocket {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var url: URL?
    private var reconnectAttempts = 0
    private var generation = 0

    public init() {}

    public func open(url: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        teardown()
        self.url = url
        reconnectAttempts = 0
        connect()
    }

    public func close() {
        dispatchPrecondition(condition: .onQueue(.main))
        teardown()
        url = nil
    }

    private func teardown() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    public func send(_ message: [String: Any]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8)
        else { return }
        let sentGeneration = generation
        task.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == sentGeneration else { return }
                self.scheduleReconnect()
            }
        }
    }

    private func connect() {
        guard let url else { return }
        var request = URLRequest(url: url)
        request.setValue("Übersicht", forHTTPHeaderField: "Origin")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        receiveNext(on: task, generation: generation)
    }

    /// Drains the socket for as long as it is open.
    ///
    /// The server broadcasts settings changes and refresh requests to every connected client,
    /// so this stream runs continuously and is not a read-one-message pattern. The previous
    /// version registered a single extra `receive` and then treated *its* completion as a
    /// failure whatever the result, which tore the connection down and rebuilt it after
    /// roughly two messages — silently dropping sends and reconnecting in a loop forever.
    private func receiveNext(on task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                switch result {
                case .success:
                    self.reconnectAttempts = 0
                    self.receiveNext(on: task, generation: generation)
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard url != nil else { return }
        teardown()
        // The original host retried after 0.1s; back off a little so a dead server does
        // not spin the CPU.
        let delay = min(0.1 * pow(2.0, Double(reconnectAttempts)), 5.0)
        reconnectAttempts += 1
        let scheduledGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == scheduledGeneration, self.task == nil else { return }
            self.connect()
        }
    }
}
