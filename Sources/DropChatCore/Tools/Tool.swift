import Foundation

/// What a tool hands back to the model.
public struct ToolOutput: Sendable {
    public var text: String
    public var images: [InlineData]
    public var isError: Bool

    public init(text: String, images: [InlineData] = [], isError: Bool = false) {
        self.text = text
        self.images = images
        self.isError = isError
    }

    public static func error(_ message: String) -> ToolOutput {
        ToolOutput(text: message, isError: true)
    }
}

/// Whether a call needs the user's go-ahead.
public enum ApprovalRequirement: Hashable, Sendable {
    /// Runs without asking.
    case none
    /// Asks, unless the user already allowed this tool for the conversation.
    case ask(reason: String)
    /// Asks every time, whatever the user allowed before (scripts, destructive tools).
    case always(reason: String)
}

public struct ToolContext: Sendable {
    public var conversationID: UUID

    public init(conversationID: UUID) {
        self.conversationID = conversationID
    }
}

/// One callable tool. Implementations should be cheap value types or
/// lightweight wrappers around a shared client (an MCP connection).
public protocol ChatTool: Sendable {
    /// What the model sees. `spec.name` must be unique in a registry.
    var spec: ToolSpec { get }
    /// What the user sees in the chat ("Search the web", "filesystem · read_file").
    var displayName: String { get }
    /// The source this tool belongs to, for grouping in the UI.
    var sourceID: String { get }

    func approval(for arguments: JSONValue) -> ApprovalRequirement
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput
}

public extension ChatTool {
    var displayName: String { spec.name }
    func approval(for arguments: JSONValue) -> ApprovalRequirement { .none }
}

/// A family of tools that share a lifecycle: one MCP server, the web tools,
/// the skills folder. The registry starts and stops sources and asks them
/// for their current tools before each model call.
public protocol ToolSource: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Connects, spawns, scans: whatever makes `tools()` meaningful.
    func start() async
    /// Releases everything `start()` acquired. Must be safe to call twice.
    func stop() async
    /// The tools available right now.
    func tools() async -> [any ChatTool]
    /// A human-readable status line ("Connected, 12 tools").
    func status() async -> ToolSourceStatus
}

public extension ToolSource {
    func start() async {}
    func stop() async {}
    func status() async -> ToolSourceStatus { .ready(detail: nil) }
}

public enum ToolSourceStatus: Hashable, Sendable {
    case idle
    case starting
    case ready(detail: String?)
    case failed(String)

    public var label: String {
        switch self {
        case .idle: return "Off"
        case .starting: return "Starting…"
        case .ready(let detail): return detail ?? "Ready"
        case .failed(let message): return message
        }
    }
}

/// A closure-backed tool, for small built-ins.
public struct FunctionTool: ChatTool {
    public let spec: ToolSpec
    public let displayName: String
    public let sourceID: String
    let requirement: @Sendable (JSONValue) -> ApprovalRequirement
    let body: @Sendable (JSONValue, ToolContext) async throws -> ToolOutput

    public init(
        spec: ToolSpec,
        displayName: String? = nil,
        sourceID: String,
        approval: @escaping @Sendable (JSONValue) -> ApprovalRequirement = { _ in .none },
        run: @escaping @Sendable (JSONValue, ToolContext) async throws -> ToolOutput
    ) {
        self.spec = spec
        self.displayName = displayName ?? spec.name
        self.sourceID = sourceID
        self.requirement = approval
        self.body = run
    }

    public func approval(for arguments: JSONValue) -> ApprovalRequirement { requirement(arguments) }

    public func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await body(arguments, context)
    }
}

/// Provider-safe tool names.
public enum ToolNaming {
    /// Maps any string onto `^[a-zA-Z0-9_-]{1,64}$`, the intersection of what
    /// the three APIs accept. Long names keep a hash suffix so they stay unique.
    public static func sanitize(_ raw: String) -> String {
        var name = String(raw.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
            return allowed || scalar == "_" || scalar == "-" ? Character(scalar) : "_"
        })
        if name.isEmpty { name = "tool" }
        if let first = name.unicodeScalars.first, !CharacterSet.letters.contains(first), first != "_" {
            name = "t_" + name
        }
        guard name.count > 64 else { return name }
        let hash = String(format: "%08x", stableHash(raw))
        return String(name.prefix(55)) + "_" + hash
    }

    /// FNV-1a, stable across launches (unlike `hashValue`).
    static func stableHash(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

/// Common argument access for tool implementations.
public extension JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue, !value.isEmpty else {
            throw ToolArgumentError.missing(key)
        }
        return value
    }
}

public enum ToolArgumentError: LocalizedError {
    case missing(String)
    case invalid(String, String)

    public var errorDescription: String? {
        switch self {
        case .missing(let key): return "The argument \"\(key)\" is required."
        case .invalid(let key, let reason): return "The argument \"\(key)\" is not valid: \(reason)"
        }
    }
}
