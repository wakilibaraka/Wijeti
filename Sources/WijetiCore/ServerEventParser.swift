import Foundation

/// The two stdout signals the host cares about. The Objective-C original scanned raw
/// output for these substrings; buffering whole lines makes that safe when a signal
/// arrives split across two reads, which pipe reads routinely do.
public enum ServerEvent: Equatable, Sendable {
    case started
    case addressInUse
}

public struct ServerEventParser: Sendable {
    private var pending: String = ""

    public init() {}

    public mutating func consume(_ chunk: Data) -> [ServerEvent] {
        consume(String(decoding: chunk, as: UTF8.self))
    }

    public mutating func consume(_ chunk: String) -> [ServerEvent] {
        pending += chunk
        var events: [ServerEvent] = []
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[pending.startIndex..<newline])
            pending = String(pending[pending.index(after: newline)...])
            if let event = ServerEventParser.event(for: line) {
                events.append(event)
            }
        }
        return events
    }

    /// Emits an event for a final line that never got its newline.
    public mutating func flush() -> [ServerEvent] {
        let line = pending
        pending = ""
        guard let event = ServerEventParser.event(for: line) else { return [] }
        return [event]
    }

    private static func event(for line: String) -> ServerEvent? {
        if line.contains("server started") { return .started }
        if line.contains("EADDRINUSE") { return .addressInUse }
        return nil
    }
}
