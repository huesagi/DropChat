import Foundation

/// How a server is reached.
public enum MCPTransportConfig: Codable, Hashable, Sendable {
    case stdio(command: String, arguments: [String], workingDirectory: String?)
    case http(url: String)

    public var isStdio: Bool {
        if case .stdio = self { return true }
        return false
    }
}

/// Which calls run without asking.
public enum MCPApprovalMode: String, Codable, CaseIterable, Sendable {
    /// Every call asks (or follows "allow for this chat").
    case ask
    /// Tools the server marks read-only run without asking.
    case readOnlyAutomatic
    /// Every tool runs without asking, except those marked destructive.
    case trusted

    public var label: String {
        switch self {
        case .ask: return "Ask every time"
        case .readOnlyAutomatic: return "Allow read-only tools"
        case .trusted: return "Allow all but destructive"
        }
    }
}

public struct MCPServerConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var transport: MCPTransportConfig
    /// Environment for stdio servers, headers for HTTP ones. Both can carry
    /// credentials, so the settings layer keeps them in the Keychain and
    /// never in preferences.
    public var environment: [String: String]
    public var headers: [String: String]
    public var approvalMode: MCPApprovalMode
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        transport: MCPTransportConfig,
        environment: [String: String] = [:],
        headers: [String: String] = [:],
        approvalMode: MCPApprovalMode = .ask,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.environment = environment
        self.headers = headers
        self.approvalMode = approvalMode
        self.isEnabled = isEnabled
    }

    public var secretAccount: String { "mcp.\(id)" }

    /// A short, provider-safe prefix for this server's tool names.
    public var toolPrefix: String {
        let slug = ToolNaming.sanitize(name.lowercased().replacingOccurrences(of: " ", with: "_"))
        return String(slug.prefix(20))
    }

    /// Reads the `mcpServers` object used by Claude Desktop, Cursor and most
    /// MCP READMEs:
    /// `{"mcpServers": {"name": {"command": "npx", "args": [...], "env": {...}}}}`
    /// or `{"name": {"url": "https://…", "headers": {...}}}`.
    public static func importing(json text: String) throws -> [MCPServerConfig] {
        let root = try JSONValue.parse(text)
        let servers = root["mcpServers"]?.objectValue ?? root["servers"]?.objectValue ?? root.objectValue ?? [:]
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] else { return nil }
            let env = (entry["env"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            let headers = (entry["headers"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            if let command = entry["command"]?.stringValue {
                let args = entry["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return MCPServerConfig(name: name, transport: .stdio(command: command, arguments: args, workingDirectory: entry["cwd"]?.stringValue), environment: env)
            }
            if let url = entry["url"]?.stringValue ?? entry["serverUrl"]?.stringValue {
                return MCPServerConfig(name: name, transport: .http(url: url), headers: headers)
            }
            return nil
        }
    }
}

/// One MCP server as a tool source.
public final class MCPToolSource: ToolSource, @unchecked Sendable {
    public let config: MCPServerConfig
    public var id: String { "mcp.\(config.id)" }
    public var displayName: String { config.name }

    private let lock = SyncLock()
    private var client: MCPClient?
    private var cachedTools: [MCPToolDescription] = []
    private var currentStatus: ToolSourceStatus = .idle
    private var connectTask: Task<Void, Never>?

    public init(config: MCPServerConfig) {
        self.config = config
    }

    public func start() async {
        // Connect in the background: a slow `npx` download must not hold up
        // the droplet's activation or the first chat.
        let task = Task { await self.connect() }
        lock.withLock { connectTask = task }
    }

    private func setStatus(_ status: ToolSourceStatus) {
        lock.withLock { currentStatus = status }
    }

    private func connect() async {
        setStatus(.starting)
        let transport: any MCPTransport
        switch config.transport {
        case .stdio(let command, let arguments, let directory):
            transport = StdioMCPTransport(
                command: command,
                arguments: arguments,
                environment: config.environment,
                workingDirectory: directory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            )
        case .http(let url):
            guard let endpoint = URL(string: url), endpoint.scheme?.hasPrefix("http") == true else {
                setStatus(.failed("The address is not a valid URL."))
                return
            }
            transport = HTTPMCPTransport(endpoint: endpoint, headers: config.headers)
        }
        let client = MCPClient(transport: transport)
        do {
            // First runs of `npx -y …` download the package; allow for it.
            try await client.connect(timeout: .seconds(config.transport.isStdio ? 120 : 30))
            await client.onToolsChanged { [weak self] in await self?.refreshTools() }
            let tools = try await client.listTools()
            guard !Task.isCancelled else {
                await client.close()
                return
            }
            lock.withLock {
                self.client = client
                self.cachedTools = tools
            }
            setStatus(.ready(detail: tools.count == 1 ? "Connected, 1 tool" : "Connected, \(tools.count) tools"))
        } catch {
            await client.close()
            setStatus(.failed(error.localizedDescription))
        }
    }

    private func refreshTools() async {
        guard let client = lock.withLock({ self.client }) else { return }
        if let tools = try? await client.listTools() {
            lock.withLock { cachedTools = tools }
            setStatus(.ready(detail: tools.count == 1 ? "Connected, 1 tool" : "Connected, \(tools.count) tools"))
        }
    }

    public func stop() async {
        let (task, client) = lock.withLock { () -> (Task<Void, Never>?, MCPClient?) in
            let result = (connectTask, self.client)
            connectTask = nil
            self.client = nil
            cachedTools = []
            currentStatus = .idle
            return result
        }
        task?.cancel()
        await client?.close()
    }

    public func status() async -> ToolSourceStatus {
        lock.withLock { currentStatus }
    }

    public func tools() async -> [any ChatTool] {
        let (client, descriptions) = lock.withLock { (self.client, cachedTools) }
        guard let client else { return [] }
        return descriptions.map { MCPTool(description: $0, server: config, client: client, sourceID: id) }
    }
}

struct MCPTool: ChatTool {
    let description: MCPToolDescription
    let server: MCPServerConfig
    let client: MCPClient
    let sourceID: String

    var spec: ToolSpec {
        ToolSpec(
            name: ToolNaming.sanitize("\(server.toolPrefix)__\(description.name)"),
            description: description.description.isEmpty ? "\(description.name) from the \(server.name) MCP server." : description.description,
            inputSchema: description.inputSchema
        )
    }

    var displayName: String { "\(server.name) · \(description.title ?? description.name)" }

    func approval(for arguments: JSONValue) -> ApprovalRequirement {
        if description.destructive {
            return .always(reason: "\(server.name) marks this tool as able to change or delete data.")
        }
        switch server.approvalMode {
        case .trusted:
            return .none
        case .readOnlyAutomatic where description.readOnly:
            return .none
        default:
            return .ask(reason: "Runs \(description.name) on the \(server.name) MCP server.")
        }
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await client.callTool(name: description.name, arguments: arguments)
    }
}
