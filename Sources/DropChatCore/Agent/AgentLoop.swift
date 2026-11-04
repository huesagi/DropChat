import Foundation

/// What the loop reports while it runs.
public enum AgentEvent: Sendable {
    /// A new model call began.
    case stepStarted(Int)
    case textDelta(String)
    case reasoningDelta(String)
    /// The model asked for a tool (shown as a pending chip).
    case toolCallReceived(ToolCall)
    case toolStarted(callID: String)
    case toolFinished(ToolResult)
    /// A message to append to the conversation: the assistant's turn, or the
    /// user-role message that carries tool results.
    case messageCompleted(ChatMessage)
    case usage(TokenUsage)
    case finished(StopReason)
}

public struct AgentOptions: Sendable {
    public var maxSteps: Int
    /// Tool output longer than this is cut, so one tool cannot fill the context.
    public var maxToolOutputCharacters: Int

    public init(maxSteps: Int = 25, maxToolOutputCharacters: Int = 80_000) {
        self.maxSteps = maxSteps
        self.maxToolOutputCharacters = maxToolOutputCharacters
    }
}

/// Calls the model, runs the tools it asks for, and calls it again until it
/// answers without tools. Owns no state between runs: the conversation lives
/// with the caller, which appends each `messageCompleted` message.
public struct AgentLoop: Sendable {
    public let provider: any LLMProvider
    public let model: String
    public let system: String?
    public let tools: [any ChatTool]
    public let approvals: any ApprovalHandler
    public let options: AgentOptions
    public let context: ToolContext
    /// Tools the user allowed for the whole conversation. Read before asking.
    public let isPreapproved: @Sendable (String) async -> Bool
    public let rememberApproval: @Sendable (String) async -> Void

    public init(
        provider: any LLMProvider,
        model: String,
        system: String?,
        tools: [any ChatTool],
        approvals: any ApprovalHandler,
        options: AgentOptions = AgentOptions(),
        context: ToolContext,
        isPreapproved: @escaping @Sendable (String) async -> Bool = { _ in false },
        rememberApproval: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.provider = provider
        self.model = model
        self.system = system
        self.tools = tools
        self.approvals = approvals
        self.options = options
        self.context = context
        self.isPreapproved = isPreapproved
        self.rememberApproval = rememberApproval
    }

    public func run(transcript initial: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        let loop = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await loop.drive(initial, emit: { _ = continuation.yield($0) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func drive(_ initial: [ChatMessage], emit: @Sendable (AgentEvent) -> Void) async throws {
        var transcript = TranscriptRepair.closeDanglingToolCalls(initial)
        let specs = tools.map(\.spec)
        let byName = Dictionary(tools.map { ($0.spec.name, $0) }, uniquingKeysWith: { first, _ in first })

        for step in 0..<options.maxSteps {
            try Task.checkCancellation()
            emit(.stepStarted(step))

            let turn = try await streamTurn(ChatRequest(model: model, system: system, messages: transcript, tools: specs), emit: emit)
            transcript.append(turn.message)
            emit(.messageCompleted(turn.message))

            let calls = turn.message.toolCalls
            guard !calls.isEmpty else {
                emit(.finished(turn.stop))
                return
            }

            let results = try await runTools(calls, byName: byName, emit: emit)
            let carrier = ChatMessage(role: .user, parts: results.map { .toolResult($0) })
            transcript.append(carrier)
            emit(.messageCompleted(carrier))
        }

        let notice = ChatMessage(role: .assistant, parts: [.text("")], model: model, notice: "Stopped after \(options.maxSteps) tool rounds. Send a message to continue.")
        emit(.messageCompleted(notice))
        emit(.finished(.other("max_steps")))
    }

    struct Turn {
        var message: ChatMessage
        var stop: StopReason
    }

    func streamTurn(_ request: ChatRequest, emit: @Sendable (AgentEvent) -> Void) async throws -> Turn {
        var builder = AssistantMessageBuilder(providerKind: provider.config.kind, model: model)
        var stop: StopReason = .endTurn
        for try await event in provider.stream(request) {
            switch event {
            case .textDelta(let text):
                builder.appendText(text)
                emit(.textDelta(text))
            case .reasoningDelta(let text):
                builder.appendReasoningDelta(text)
                emit(.reasoningDelta(text))
            case .reasoningBlock(let block):
                builder.appendReasoningBlock(block)
            case .toolCall(let call):
                builder.appendToolCall(call)
                emit(.toolCallReceived(call))
            case .fallbackBoundary:
                builder.dropReplayOnlyParts()
            case .usage(let usage):
                emit(.usage(usage))
            case .modelInfo(let name):
                builder.model = name
            case .finished(let reason):
                stop = reason
            }
        }
        var message = builder.build()
        switch stop {
        case .refusal(let explanation):
            message.notice = explanation ?? "The model declined to answer this request."
        case .maxTokens:
            message.notice = "The answer hit the output limit and was cut off."
        default:
            break
        }
        return Turn(message: message, stop: stop)
    }

    func runTools(_ calls: [ToolCall], byName: [String: any ChatTool], emit: @Sendable (AgentEvent) -> Void) async throws -> [ToolResult] {
        // Approvals first, one at a time, so the user sees a single prompt.
        var approved: [String: Bool] = [:]
        for call in calls {
            try Task.checkCancellation()
            guard call.argumentError == nil, let tool = byName[call.name] else { continue }
            switch tool.approval(for: call.arguments) {
            case .none:
                approved[call.id] = true
            case .ask(let reason):
                if await isPreapproved(call.name) {
                    approved[call.id] = true
                    continue
                }
                let decision = await approvals.decide(ApprovalRequest(call: call, toolDisplayName: tool.displayName, reason: reason, asksEveryTime: false))
                if case .allowForConversation = decision { await rememberApproval(call.name) }
                approved[call.id] = decision != .deny
            case .always(let reason):
                let decision = await approvals.decide(ApprovalRequest(call: call, toolDisplayName: tool.displayName, reason: reason, asksEveryTime: true))
                approved[call.id] = decision != .deny
            }
        }
        try Task.checkCancellation()

        let context = self.context
        let limit = options.maxToolOutputCharacters
        return await withTaskGroup(of: (Int, ToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                let tool = byName[call.name]
                let isApproved = approved[call.id] ?? false
                emit(.toolStarted(callID: call.id))
                group.addTask {
                    let result: ToolResult
                    if let error = call.argumentError {
                        result = ToolResult(callID: call.id, toolName: call.name, text: error, isError: true)
                    } else if let tool {
                        if isApproved {
                            do {
                                let output = try await tool.run(call.arguments, context: context)
                                result = ToolResult(callID: call.id, toolName: call.name, text: Self.truncate(output.text, limit: limit), images: output.images, isError: output.isError)
                            } catch is CancellationError {
                                result = ToolResult(callID: call.id, toolName: call.name, text: "The user stopped this tool call.", isError: true)
                            } catch {
                                result = ToolResult(callID: call.id, toolName: call.name, text: error.localizedDescription, isError: true)
                            }
                        } else {
                            result = ToolResult(callID: call.id, toolName: call.name, text: "The user declined this tool call. Do not retry it unless they ask.", isError: true)
                        }
                    } else {
                        result = ToolResult(callID: call.id, toolName: call.name, text: "There is no tool named \(call.name).", isError: true)
                    }
                    return (index, result)
                }
            }
            var results = [ToolResult?](repeating: nil, count: calls.count)
            for await (index, result) in group {
                results[index] = result
                emit(.toolFinished(result))
            }
            return results.compactMap { $0 }
        }
    }

    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n[Output truncated: \(text.count - limit) more characters.]"
    }
}

/// Assembles the assistant message from stream events, keeping part order.
struct AssistantMessageBuilder {
    let providerKind: ProviderKind
    var model: String
    private var parts: [ContentPart] = []
    private var pendingReasoning = ""
    private var receivedReasoningBlocks = false

    init(providerKind: ProviderKind, model: String) {
        self.providerKind = providerKind
        self.model = model
    }

    mutating func appendText(_ text: String) {
        flushDisplayReasoning()
        if case .text(let existing)? = parts.last {
            parts[parts.count - 1] = .text(existing + text)
        } else {
            parts.append(.text(text))
        }
    }

    mutating func appendReasoningDelta(_ text: String) {
        pendingReasoning += text
    }

    /// A signed block replaces the deltas that streamed it.
    mutating func appendReasoningBlock(_ block: ReasoningContent) {
        receivedReasoningBlocks = true
        pendingReasoning = ""
        parts.append(.reasoning(block))
    }

    mutating func appendToolCall(_ call: ToolCall) {
        flushDisplayReasoning()
        parts.append(.toolCall(call))
    }

    /// After a server-side model fallback, reasoning and tool calls from the
    /// declined attempt must not be echoed back.
    mutating func dropReplayOnlyParts() {
        pendingReasoning = ""
        parts.removeAll {
            switch $0 {
            case .reasoning, .toolCall: return true
            default: return false
            }
        }
    }

    /// Unsigned reasoning (OpenAI-compatible, Gemini) is kept for display.
    private mutating func flushDisplayReasoning() {
        guard !pendingReasoning.isEmpty, !receivedReasoningBlocks else { return }
        parts.append(.reasoning(ReasoningContent(providerKind: providerKind, text: pendingReasoning)))
        pendingReasoning = ""
    }

    mutating func build() -> ChatMessage {
        flushDisplayReasoning()
        return ChatMessage(role: .assistant, parts: parts, model: model)
    }
}

/// Keeps a transcript valid for every API after interruptions.
public enum TranscriptRepair {
    /// Every tool call must be answered by a result in the next message.
    /// A run stopped between the two leaves calls dangling, which the APIs
    /// reject, so answer them with a "stopped" error.
    public static func closeDanglingToolCalls(_ messages: [ChatMessage]) -> [ChatMessage] {
        var output: [ChatMessage] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            output.append(message)
            index += 1
            let calls = message.toolCalls
            guard message.role == .assistant, !calls.isEmpty else { continue }
            let next = index < messages.count ? messages[index] : nil
            let answered = Set(next?.toolResults.map(\.callID) ?? [])
            let missing = calls.filter { !answered.contains($0.id) }
            guard !missing.isEmpty else { continue }
            let stopped = missing.map {
                ContentPart.toolResult(ToolResult(callID: $0.id, toolName: $0.name, text: "The user stopped this tool call before it finished.", isError: true))
            }
            if let next, next.role == .user, !next.toolResults.isEmpty {
                // Merge into the carrier that follows.
                var merged = next
                merged.parts += stopped
                output.append(merged)
                index += 1
            } else {
                output.append(ChatMessage(role: .user, parts: stopped))
            }
        }
        return output
    }
}
