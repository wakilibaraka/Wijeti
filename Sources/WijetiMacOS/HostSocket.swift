import Foundation

/// The host's own connection to the widget server's message bus.
///
/// The server relays any JSON a client sends to every other client (`MessageBus`), and it
/// only accepts connections whose `Origin` is the widget origin or the literal `Übersicht`
/// string the original host sent. This is how the tray menu's Refresh, the preferences
/// toggles and AppleScript property writes reach every open widget without reloading a
/// page — the same mechanism as `UBWebSocket` plus `dispatch.js`.
public final class HostSocket {
    private var task: URLSessionWebSocketTask?
    private var url: URL?
    private var reconnectAttempts = 0

    public init() {}

    public func open(url: URL) {
        self.url = url
        reconnectAttempts = 0
        connect()
    }

    public func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        url = nil
    }

    public func send(_ message: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            self?.scheduleReconnect()
        }
    }

    private func connect() {
        guard let url else { return }
        var request = URLRequest(url: url)
        request.setValue("Übersicht", forHTTPHeaderField: "Origin")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveNext()
    }

    /// Drains the socket for as long as it is open.
    ///
    /// The server broadcasts settings changes and refresh requests to every connected client,
    /// so this stream runs continuously and is not a read-one-message pattern. The previous
    /// version registered a single extra `receive` and then treated *its* completion as a
    /// failure whatever the result, which tore the connection down and rebuilt it after
    /// roughly two messages — silently dropping sends and reconnecting in a loop forever.
    private func receiveNext() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.reconnectAttempts = 0
                self.receiveNext()
            case .failure:
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard url != nil else { return }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // The original host retried after 0.1s; back off a little so a dead server does
        // not spin the CPU.
        let delay = min(0.1 * pow(2.0, Double(reconnectAttempts)), 5.0)
        reconnectAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }
}
