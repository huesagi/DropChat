import Foundation

/// Every tool source the chat can draw on. An actor: sources are started and
/// stopped from settings changes while a chat may be listing tools.
public actor ToolRegistry {
    private var sources: [String: any ToolSource] = [:]
    private var order: [String] = []

    public init() {}

    /// Adds (or replaces) a source and starts it.
    public func install(_ source: any ToolSource) async {
        if let existing = sources[source.id] {
            await existing.stop()
        } else {
            order.append(source.id)
        }
        sources[source.id] = source
        await source.start()
    }

    public func remove(id: String) async {
        guard let source = sources.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        await source.stop()
    }

    public func stopAll() async {
        for id in order {
            await sources[id]?.stop()
        }
        sources.removeAll()
        order.removeAll()
    }

    public func source(id: String) -> (any ToolSource)? { sources[id] }

    public var sourceIDs: [String] { order }

    /// All tools, in source order, with duplicate names dropped (first wins).
    public func availableTools() async -> [any ChatTool] {
        var seen = Set<String>()
        var tools: [any ChatTool] = []
        for id in order {
            guard let source = sources[id] else { continue }
            for tool in await source.tools() where seen.insert(tool.spec.name).inserted {
                tools.append(tool)
            }
        }
        return tools
    }

    public func statuses() async -> [(id: String, name: String, status: ToolSourceStatus)] {
        var result: [(id: String, name: String, status: ToolSourceStatus)] = []
        for id in order {
            guard let source = sources[id] else { continue }
            result.append((id, source.displayName, await source.status()))
        }
        return result
    }
}

// MARK: - Approval

public struct ApprovalRequest: Sendable, Identifiable {
    public var id: String { call.id }
    public var call: ToolCall
    public var toolDisplayName: String
    public var reason: String
    /// When true the "allow for this chat" choice is not offered.
    public var asksEveryTime: Bool

    public init(call: ToolCall, toolDisplayName: String, reason: String, asksEveryTime: Bool) {
        self.call = call
        self.toolDisplayName = toolDisplayName
        self.reason = reason
        self.asksEveryTime = asksEveryTime
    }
}

public enum ApprovalDecision: Sendable {
    case allowOnce
    case allowForConversation
    case deny
}

/// Implemented by the UI. Called one request at a time.
public protocol ApprovalHandler: Sendable {
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision
}

/// Tools the user allowed for the rest of a conversation ("Allow for this
/// chat"). Owned by the chat; the agent loop reads and writes it.
public final class ToolApprovalMemory: @unchecked Sendable {
    private let lock = SyncLock()
    private var allowed: Set<String> = []

    public init() {}

    public func contains(_ toolName: String) -> Bool {
        lock.withLock { allowed.contains(toolName) }
    }

    public func remember(_ toolName: String) {
        lock.withLock { _ = allowed.insert(toolName) }
    }

    public func reset() {
        lock.withLock { allowed.removeAll() }
    }
}

/// Grants everything. For tests and for tools that need no approval.
public struct AutoApprove: ApprovalHandler {
    public init() {}
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision { .allowOnce }
}
