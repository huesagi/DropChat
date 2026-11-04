import Foundation

/// A tool as an MCP server describes it.
public struct MCPToolDescription: Sendable, Hashable {
    public var name: String
    public var title: String?
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool
}

/// A minimal MCP client: lifecycle, tools, and the server requests a client
/// must answer. One per server.
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"

    private let transport: any MCPTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var isClosed = false
    public private(set) var serverName: String?
    public private(set) var instructions: String?
    private var toolsChangedHandler: (@Sendable () async -> Void)?

    public init(transport: any MCPTransport) {
        self.transport = transport
    }

    public func onToolsChanged(_ handler: @escaping @Sendable () async -> Void) {
        toolsChangedHandler = handler
    }

    /// Starts the transport and runs the initialize handshake.
    public func connect(timeout: Duration = .seconds(30)) async throws {
        try await transport.start()
        let stream = transport.incoming
        readTask = Task { [weak self] in
            for await message in stream {
                await self?.handle(message)
            }
            await self?.transportEnded()
        }
        let result = try await request("initialize", params: [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": [:],
            "clientInfo": ["name": "DropChat", "version": "0.1.0"],
        ], timeout: timeout)
        if let version = result["protocolVersion"]?.stringValue, let http = transport as? HTTPMCPTransport {
            http.setProtocolVersion(version)
        }
        serverName = result["serverInfo"]?["name"]?.stringValue
        instructions = result["instructions"]?.stringValue
        try await notify("notifications/initialized")
    }

    public func close() async {
        isClosed = true
        readTask?.cancel()
        await transport.close()
        failPending(MCPError.closed(nil))
    }

    public func listTools() async throws -> [MCPToolDescription] {
        var tools: [MCPToolDescription] = []
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await request("tools/list", params: .object(params))
            for item in result["tools"]?.arrayValue ?? [] {
                guard let name = item["name"]?.stringValue else { continue }
                let annotations = item["annotations"] ?? .null
                tools.append(MCPToolDescription(
                    name: name,
                    title: item["title"]?.stringValue ?? annotations["title"]?.stringValue,
                    description: item["description"]?.stringValue ?? "",
                    inputSchema: item["inputSchema"] ?? ["type": "object", "properties": [:]],
                    readOnly: annotations["readOnlyHint"]?.boolValue ?? false,
                    destructive: annotations["destructiveHint"]?.boolValue ?? false
                ))
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil && tools.count < 2_000
        return tools
    }

    public func callTool(name: String, arguments: JSONValue, timeout: Duration = .seconds(300)) async throws -> ToolOutput {
        let result = try await request("tools/call", params: ["name": .string(name), "arguments": arguments], timeout: timeout)
        return Self.output(from: result)
    }

    static func output(from result: JSONValue) -> ToolOutput {
        var texts: [String] = []
        var images: [InlineData] = []
        for item in result["content"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "text":
                texts.append(item["text"]?.stringValue ?? "")
            case "image":
                if let data = item["data"]?.stringValue {
                    images.append(InlineData(mediaType: item["mimeType"]?.stringValue ?? "image/png", base64: data))
                }
            case "audio":
                texts.append("[audio content omitted]")
            case "resource":
                let resource = item["resource"] ?? .null
                if let text = resource["text"]?.stringValue {
                    texts.append("<resource uri=\"\(resource["uri"]?.stringValue ?? "")\">\n\(text)\n</resource>")
                } else if let uri = resource["uri"]?.stringValue {
                    texts.append("[binary resource \(uri)]")
                }
            case "resource_link":
                texts.append("[resource \(item["name"]?.stringValue ?? "") at \(item["uri"]?.stringValue ?? "")]")
            default:
                break
            }
        }
        if texts.isEmpty, let structured = result["structuredContent"], !structured.isNull {
            texts.append(structured.prettyPrinted())
        }
        return ToolOutput(text: texts.joined(separator: "\n"), images: images, isError: result["isError"]?.boolValue ?? false)
    }

    // MARK: - JSON-RPC

    public func request(_ method: String, params: JSONValue = [:], timeout: Duration = .seconds(60)) async throws -> JSONValue {
        guard !isClosed else { throw MCPError.notConnected }
        let id = nextID
        nextID += 1
        let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]

        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.expire(id: id, method: method)
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                pending[id] = continuation
                Task {
                    do {
                        try await transport.send(message)
                    } catch {
                        self.resolve(id: id, with: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    public func notify(_ method: String, params: JSONValue? = nil) async throws {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        try await transport.send(.object(message))
    }

    private func expire(id: Int, method: String) {
        resolve(id: id, with: .failure(MCPError.timeout(method)))
    }

    private func cancelRequest(id: Int) {
        guard pending[id] != nil else { return }
        resolve(id: id, with: .failure(CancellationError()))
        Task { try? await notify("notifications/cancelled", params: ["requestId": .number(Double(id)), "reason": "The user stopped the request."]) }
    }

    private func resolve(id: Int, with result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failPending(_ error: Error) {
        let continuations = pending
        pending.removeAll()
        continuations.values.forEach { $0.resume(throwing: error) }
    }

    private func transportEnded() async {
        let detail = await transport.diagnostics()
        failPending(MCPError.closed(detail))
        isClosed = true
    }

    private func handle(_ message: JSONValue) async {
        let method = message["method"]?.stringValue
        let id = message["id"]

        // A response to one of our requests.
        if method == nil, let id, let number = id.intValue {
            if let error = message["error"] {
                resolve(id: number, with: .failure(MCPError.server(
                    code: error["code"]?.intValue ?? -1,
                    message: error["message"]?.stringValue ?? "The MCP server reported an error."
                )))
            } else {
                resolve(id: number, with: .success(message["result"] ?? .null))
            }
            return
        }

        guard let method else { return }
        if let id {
            // A request from the server.
            let reply: JSONValue
            switch method {
            case "ping":
                reply = ["jsonrpc": "2.0", "id": id, "result": [:]]
            case "roots/list":
                reply = ["jsonrpc": "2.0", "id": id, "result": ["roots": []]]
            default:
                reply = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "DropChat does not support \(method)."]]
            }
            try? await transport.send(reply)
            return
        }

        if method == "notifications/tools/list_changed", let handler = toolsChangedHandler {
            await handler()
        }
    }
}
