import Foundation

/// Moves JSON-RPC messages between DropChat and one MCP server.
public protocol MCPTransport: AnyObject, Sendable {
    /// Messages from the server: responses, notifications and requests.
    var incoming: AsyncStream<JSONValue> { get }
    func start() async throws
    func send(_ message: JSONValue) async throws
    func close() async
    /// The last lines the server wrote to stderr, for error messages.
    func diagnostics() async -> String?
}

public enum MCPError: LocalizedError {
    case notConnected
    case timeout(String)
    case server(code: Int, message: String)
    case transport(String)
    case closed(String?)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "The MCP server is not connected."
        case .timeout(let method): return "The MCP server did not answer \(method) in time."
        case .server(_, let message): return message
        case .transport(let message): return message
        case .closed(let detail):
            if let detail, !detail.isEmpty { return "The MCP server stopped: \(detail)" }
            return "The MCP server stopped."
        }
    }
}

// MARK: - stdio

/// A local server started as a child process, speaking newline-delimited
/// JSON-RPC over stdin/stdout.
public final class StdioMCPTransport: MCPTransport, @unchecked Sendable {
    public let incoming: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: URL?

    private let lock = SyncLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var stderrTail = ""
    private let writeQueue = DispatchQueue(label: "dropchat.mcp.stdio.write")

    public init(command: String, arguments: [String], environment: [String: String], workingDirectory: URL?) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        (incoming, continuation) = AsyncStream.makeStream(of: JSONValue.self)
    }

    public func start() async throws {
        let environment = ProcessRunner.augmentedEnvironment(self.environment)
        guard let executable = ProcessRunner.resolveExecutable(command, environment: environment) else {
            throw MCPError.transport("Could not find \"\(command)\". Use a full path, or install it where Homebrew or npm put tools.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let continuation = self.continuation
        process.terminationHandler = { _ in continuation.finish() }
        do {
            try process.run()
        } catch {
            throw MCPError.transport("\"\(command)\" could not start: \(error.localizedDescription)")
        }
        lock.lock()
        self.process = process
        self.stdin = input.fileHandleForWriting
        lock.unlock()

        // Each pipe is read on a thread of its own, never the main actor or
        // a cooperative thread.
        let stdout = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            while true {
                let chunk = stdout.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    if let message = try? JSONValue.parse(Data(line)) {
                        continuation.yield(message)
                    }
                }
            }
            continuation.finish()
        }
        let stderr = errors.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let chunk = stderr.availableData
                if chunk.isEmpty { break }
                self?.appendStderr(String(decoding: chunk, as: UTF8.self))
            }
        }
    }

    private func appendStderr(_ text: String) {
        lock.lock()
        stderrTail = String((stderrTail + text).suffix(2_000))
        lock.unlock()
    }

    public func diagnostics() async -> String? {
        lock.lock()
        defer { lock.unlock() }
        let text = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func send(_ message: JSONValue) async throws {
        lock.lock()
        let handle = stdin
        let running = process?.isRunning ?? false
        lock.unlock()
        guard let handle, running else { throw MCPError.notConnected }
        var data = message.serializedData()
        data.append(UInt8(ascii: "\n"))
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    try handle.write(contentsOf: data)
                    resume.resume()
                } catch {
                    resume.resume(throwing: MCPError.transport(error.localizedDescription))
                }
            }
        }
    }

    public func close() async {
        lock.lock()
        let process = self.process
        let handle = stdin
        self.process = nil
        self.stdin = nil
        lock.unlock()
        try? handle?.close()
        guard let process, process.isRunning else {
            continuation.finish()
            return
        }
        let group = -process.processIdentifier
        kill(group, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(group, SIGKILL) }
        }
        continuation.finish()
    }
}

// MARK: - Streamable HTTP

/// A remote server reached over MCP's Streamable HTTP transport: every
/// client message is a POST; the answer is JSON or an SSE stream.
public final class HTTPMCPTransport: MCPTransport, @unchecked Sendable {
    public let incoming: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation
    private let endpoint: URL
    private let headers: [String: String]
    private let session: URLSession

    private let lock = SyncLock()
    private var sessionID: String?
    private var protocolVersion: String?
    private var lastError: String?
    private var tasks: [Task<Void, Never>] = []

    public init(endpoint: URL, headers: [String: String]) {
        self.endpoint = endpoint
        self.headers = headers
        self.session = URLSession(configuration: .default)
        (incoming, continuation) = AsyncStream.makeStream(of: JSONValue.self)
    }

    public func start() async throws {}

    public func setProtocolVersion(_ version: String) {
        lock.lock()
        protocolVersion = version
        lock.unlock()
    }

    private func makeRequest(method: String, body: JSONValue?) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body.serializedData()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        lock.lock()
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        lock.unlock()
        return request
    }

    public func send(_ message: JSONValue) async throws {
        let request = makeRequest(method: "POST", body: message)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.transport("The server sent no HTTP response.") }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            lock.lock()
            sessionID = id
            lock.unlock()
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 16_000 { break }
            }
            let message = "HTTP \(http.statusCode): \(HTTPErrorBody.message(from: body))"
            lock.lock()
            lastError = message
            lock.unlock()
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MCPError.transport("The server refused the credentials (\(http.statusCode)). Check the token in DropChat's MCP settings.")
            }
            throw MCPError.transport(message)
        }
        if http.statusCode == 202 { return }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let continuation = self.continuation
        if contentType.contains("text/event-stream") {
            // Read the stream in the background; responses are routed by id.
            let task = Task {
                var parser = SSEParser()
                var line = Data()
                do {
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if line.last == UInt8(ascii: "\r") { line.removeLast() }
                            if let event = parser.feed(String(decoding: line, as: UTF8.self)) {
                                HTTPMCPTransport.deliver(event.data, to: continuation)
                            }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    if let event = parser.finish() { HTTPMCPTransport.deliver(event.data, to: continuation) }
                } catch {}
            }
            lock.lock()
            tasks.append(task)
            lock.unlock()
        } else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            HTTPMCPTransport.deliver(String(decoding: body, as: UTF8.self), to: continuation)
        }
    }

    static func deliver(_ text: String, to continuation: AsyncStream<JSONValue>.Continuation) {
        guard let value = try? JSONValue.parse(text) else { return }
        if case .array(let batch) = value {
            batch.forEach { continuation.yield($0) }
        } else {
            continuation.yield(value)
        }
    }

    public func diagnostics() async -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastError
    }

    public func close() async {
        lock.lock()
        let tasks = self.tasks
        self.tasks = []
        let hadSession = sessionID != nil
        lock.unlock()
        tasks.forEach { $0.cancel() }
        if hadSession {
            _ = try? await session.data(for: makeRequest(method: "DELETE", body: nil))
        }
        continuation.finish()
    }
}
