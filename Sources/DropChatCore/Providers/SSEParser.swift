import Foundation

public struct SSEEvent: Hashable, Sendable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Server-Sent Events framing (WHATWG), fed one line at a time.
public struct SSEParser: Sendable {
    private var event: String?
    private var dataLines: [String] = []
    private var id: String?

    public init() {}

    /// Feeds one line (without its terminator). Returns an event when the
    /// line completes one.
    public mutating func feed(_ line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        case "id": id = String(value)
        default: break
        }
        return nil
    }

    /// Flushes an event left open at the end of the stream.
    public mutating func finish() -> SSEEvent? { dispatch() }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            event = nil
            dataLines = []
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: event, data: dataLines.joined(separator: "\n"), id: id)
    }
}

public extension AsyncThrowingStream where Element == String, Failure == Error {
    /// Groups lines into SSE events.
    func sseEvents() -> AsyncThrowingStream<SSEEvent, Error> {
        let lines = self
        return AsyncThrowingStream<SSEEvent, Error> { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await line in lines {
                        if let event = parser.feed(line) { continuation.yield(event) }
                    }
                    if let event = parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
