import XCTest
@testable import DropChatCore

final class SSEParserTests: XCTestCase {
    func testEventsSplitOnBlankLines() {
        var parser = SSEParser()
        let lines = ["event: message_start", "data: {\"a\":1}", "", ": comment", "data: line1", "data: line2", ""]
        let events = lines.compactMap { parser.feed($0) }
        XCTAssertEqual(events, [
            SSEEvent(event: "message_start", data: "{\"a\":1}"),
            SSEEvent(event: nil, data: "line1\nline2"),
        ])
    }

    func testFinishFlushesOpenEvent() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed("data: tail"))
        XCTAssertEqual(parser.finish(), SSEEvent(data: "tail"))
    }
}

final class OpenAIWireTests: XCTestCase {
    func testToolCallDeltasAreAssembled() throws {
        var decoder = OpenAIChatStreamDecoder()
        let chunks = [
            #"{"model":"gpt-x","choices":[{"delta":{"content":"Hi"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"web_search","arguments":"{\"que"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ry\":\"swift\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ]
        var events: [StreamEvent] = []
        for chunk in chunks { events += try decoder.feed(SSEEvent(data: chunk)) }
        events += try decoder.feed(SSEEvent(data: "[DONE]"))

        let calls = events.compactMap { if case .toolCall(let call) = $0 { return call } else { return nil } }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call_1")
        XCTAssertEqual(calls[0].arguments["query"]?.stringValue, "swift")
        XCTAssertNil(calls[0].argumentError)
        guard case .finished(.toolUse)? = events.last else { return XCTFail("expected tool-use stop") }
    }

    func testEncoderMapsToolResultsToToolMessages() {
        let config = ProviderConfig(kind: .openAI)
        let call = ToolCall(id: "c1", name: "t", arguments: ["x": 1])
        let request = ChatRequest(model: "m", system: "sys", messages: [
            .user("hello"),
            ChatMessage(role: .assistant, parts: [.text("ok"), .toolCall(call)]),
            ChatMessage(role: .user, parts: [.toolResult(ToolResult(callID: "c1", toolName: "t", text: "42"))]),
        ], tools: [ToolSpec(name: "t", description: "d", inputSchema: ["type": "object"])])
        let body = OpenAIChatEncoder(config: config).body(for: request)
        let messages = body["messages"]?.arrayValue ?? []
        XCTAssertEqual(messages.map { $0["role"]?.stringValue }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(messages[2]["tool_calls"]?[0]?["function"]?["arguments"]?.stringValue, #"{"x":1}"#)
        XCTAssertEqual(messages[3]["tool_call_id"]?.stringValue, "c1")
        XCTAssertEqual(body["tools"]?[0]?["function"]?["name"]?.stringValue, "t")
    }

    func testTruncatedArgumentsBecomeAnError() {
        let call = ToolArguments.makeCall(id: "1", name: "x", json: #"{"a": "unterminated"#)
        XCTAssertNotNil(call.argumentError)
    }
}

final class AnthropicWireTests: XCTestCase {
    func testThinkingAndToolUseStream() throws {
        var decoder = AnthropicStreamDecoder()
        let events: [String] = [
            #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Checking."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"news\"}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}"#,
            #"{"type":"message_stop"}"#,
        ]
        var output: [StreamEvent] = []
        for event in events { output += try decoder.feed(SSEEvent(data: event)) }

        let blocks = output.compactMap { if case .reasoningBlock(let block) = $0 { return block } else { return nil } }
        XCTAssertEqual(blocks.first?.text, "Let me think")
        XCTAssertEqual(blocks.first?.signature, "sig")
        let calls = output.compactMap { if case .toolCall(let call) = $0 { return call } else { return nil } }
        XCTAssertEqual(calls.first?.arguments["query"]?.stringValue, "news")
        guard case .finished(.toolUse)? = output.last else { return XCTFail("expected tool-use stop") }
    }

    func testEncoderReplaysSignedThinkingAndSetsDefaults() {
        let config = ProviderConfig(kind: .anthropic)
        let message = ChatMessage(role: .assistant, parts: [
            .reasoning(ReasoningContent(providerKind: .anthropic, text: "t", signature: "s")),
            .reasoning(ReasoningContent(providerKind: .google, text: "not replayed")),
            .toolCall(ToolCall(id: "a", name: "n", arguments: [:])),
        ])
        let request = ChatRequest(model: "claude-opus-5-5", system: nil, messages: [.user("q"), message], tools: [ToolSpec(name: "n", description: "", inputSchema: ["type": "object"])])
        let encoder = AnthropicEncoder(config: config)
        let body = encoder.body(for: request)
        let content = body["messages"]?[1]?["content"]?.arrayValue ?? []
        XCTAssertEqual(content.map { $0["type"]?.stringValue }, ["thinking", "tool_use"])
        XCTAssertEqual(body["thinking"]?["type"]?.stringValue, "adaptive")
        XCTAssertEqual(body["fallbacks"]?.stringValue, "default")
        XCTAssertEqual(body["tools"]?[0]?["eager_input_streaming"]?.boolValue, true)
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(encoder.betas(for: request), [AnthropicProvider.fallbackBeta])
    }

    func testRefusalStopReason() throws {
        var decoder = AnthropicStreamDecoder()
        _ = try decoder.feed(SSEEvent(data: #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"explanation":"no"}}}"#))
        let output = try decoder.feed(SSEEvent(data: #"{"type":"message_stop"}"#))
        guard case .finished(.refusal("no"))? = output.last else { return XCTFail("expected refusal") }
    }
}

final class GeminiWireTests: XCTestCase {
    func testFunctionCallKeepsThoughtSignature() throws {
        var decoder = GeminiStreamDecoder()
        var output = try decoder.feed(SSEEvent(data: #"{"candidates":[{"content":{"parts":[{"text":"thinking…","thought":true},{"functionCall":{"name":"web_fetch","args":{"urls":["https://a.b"]}},"thoughtSignature":"abc"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":3}}"#))
        output += decoder.finish()
        let calls = output.compactMap { if case .toolCall(let call) = $0 { return call } else { return nil } }
        XCTAssertEqual(calls.first?.providerMetadata?[GeminiEncoder.signatureKey], "abc")
        guard case .finished(.toolUse)? = output.last else { return XCTFail("expected tool-use stop") }

        let encoded = GeminiEncoder(config: ProviderConfig(kind: .google)).part(for: .toolCall(calls[0]))
        XCTAssertEqual(encoded?[GeminiEncoder.signatureKey]?.stringValue, "abc")
    }
}

final class AgentLoopTests: XCTestCase {
    struct ScriptedProvider: LLMProvider {
        let config = ProviderConfig(kind: .openAICompatible)
        let turns: [[StreamEvent]]
        let counter = Counter()

        func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            let index = counter.next()
            let events = index < turns.count ? turns[index] : [.textDelta("done"), .finished(.endTurn)]
            return AsyncThrowingStream { continuation in
                events.forEach { continuation.yield($0) }
                continuation.finish()
            }
        }

        func listModels() async throws -> [ModelInfo] { [] }
    }

    final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = SyncLock()
        func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
    }

    struct Deny: ApprovalHandler {
        func decide(_ request: ApprovalRequest) async -> ApprovalDecision { .deny }
    }

    func makeTool(approval: ApprovalRequirement) -> FunctionTool {
        FunctionTool(spec: ToolSpec(name: "echo", description: "", inputSchema: ["type": "object"]), sourceID: "test", approval: { _ in approval }) { arguments, _ in
            ToolOutput(text: "echo: \(arguments["v"]?.stringValue ?? "")")
        }
    }

    func run(_ loop: AgentLoop) async throws -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for try await event in loop.run(transcript: [.user("go")]) {
            if case .messageCompleted(let message) = event { messages.append(message) }
        }
        return messages
    }

    func testRunsToolsAndContinues() async throws {
        let provider = ScriptedProvider(turns: [
            [.textDelta("Calling"), .toolCall(ToolCall(id: "1", name: "echo", arguments: ["v": "hi"])), .finished(.toolUse)],
        ])
        let loop = AgentLoop(provider: provider, model: "m", system: nil, tools: [makeTool(approval: .none)], approvals: AutoApprove(), context: ToolContext(conversationID: UUID()))
        let messages = try await run(loop)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[1].toolResults.first?.text, "echo: hi")
        XCTAssertEqual(messages[2].plainText, "done")
    }

    func testDeniedToolReturnsError() async throws {
        let provider = ScriptedProvider(turns: [
            [.toolCall(ToolCall(id: "1", name: "echo", arguments: [:])), .finished(.toolUse)],
        ])
        let loop = AgentLoop(provider: provider, model: "m", system: nil, tools: [makeTool(approval: .always(reason: "x"))], approvals: Deny(), context: ToolContext(conversationID: UUID()))
        let messages = try await run(loop)
        XCTAssertEqual(messages[1].toolResults.first?.isError, true)
    }

    func testUnknownToolAndBadArguments() async throws {
        let provider = ScriptedProvider(turns: [[
            .toolCall(ToolCall(id: "1", name: "missing", arguments: [:])),
            .toolCall(ToolCall(id: "2", name: "echo", arguments: [:], argumentError: "bad json")),
            .finished(.toolUse),
        ]])
        let loop = AgentLoop(provider: provider, model: "m", system: nil, tools: [makeTool(approval: .none)], approvals: AutoApprove(), context: ToolContext(conversationID: UUID()))
        let messages = try await run(loop)
        let results = messages[1].toolResults
        XCTAssertEqual(results.map(\.callID), ["1", "2"])
        XCTAssertTrue(results.allSatisfy(\.isError))
    }

    func testFallbackBoundaryDropsReplayOnlyParts() {
        var builder = AssistantMessageBuilder(providerKind: .anthropic, model: "m")
        builder.appendReasoningBlock(ReasoningContent(providerKind: .anthropic, text: "r", signature: "s"))
        builder.appendText("partial ")
        builder.appendToolCall(ToolCall(id: "1", name: "x", arguments: [:]))
        builder.dropReplayOnlyParts()
        builder.appendText("rest")
        let message = builder.build()
        XCTAssertEqual(message.parts, [.text("partial rest")])
    }
}

final class TranscriptRepairTests: XCTestCase {
    func testDanglingCallsGetResults() {
        let messages = [
            ChatMessage.user("q"),
            ChatMessage(role: .assistant, parts: [.toolCall(ToolCall(id: "a", name: "t", arguments: [:])), .toolCall(ToolCall(id: "b", name: "t", arguments: [:]))]),
            ChatMessage(role: .user, parts: [.toolResult(ToolResult(callID: "a", toolName: "t", text: "ok"))]),
        ]
        let repaired = TranscriptRepair.closeDanglingToolCalls(messages)
        XCTAssertEqual(repaired.count, 3)
        XCTAssertEqual(repaired[2].toolResults.map(\.callID), ["a", "b"])
    }

    func testCallAtEndGetsCarrier() {
        let repaired = TranscriptRepair.closeDanglingToolCalls([
            ChatMessage(role: .assistant, parts: [.toolCall(ToolCall(id: "a", name: "t", arguments: [:]))]),
        ])
        XCTAssertEqual(repaired.count, 2)
        XCTAssertTrue(repaired[1].isToolResultCarrier)
    }
}

final class SkillsTests: XCTestCase {
    func testFrontmatter() {
        let document = """
        ---
        name: pdf-tools
        description: >
          Fill and merge
          PDF forms.
        license: "MIT"
        ---
        # Body
        """
        let (fields, body) = Frontmatter.split(document)
        XCTAssertEqual(fields["name"], "pdf-tools")
        XCTAssertEqual(fields["description"], "Fill and merge PDF forms.")
        XCTAssertEqual(fields["license"], "MIT")
        XCTAssertEqual(body, "# Body")
    }

    func testDiscoveryAndPathConfinement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skillDir = root.appendingPathComponent("greeter")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: greeter\ndescription: Says hi.\n---\nSay hi.".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let skills = SkillLoader.discover(in: [root])
        XCTAssertEqual(skills.map(\.name), ["greeter"])
        XCTAssertNoThrow(try SkillLoader.resolve("SKILL.md", in: skills[0]))
        XCTAssertThrowsError(try SkillLoader.resolve("../../etc/passwd", in: skills[0]))
    }
}

final class MiscTests: XCTestCase {
    func testToolNaming() {
        XCTAssertEqual(ToolNaming.sanitize("my server__read file"), "my_server__read_file")
        XCTAssertEqual(ToolNaming.sanitize("9lives"), "t_9lives")
        let long = ToolNaming.sanitize(String(repeating: "a", count: 100))
        XCTAssertEqual(long.count, 64)
        XCTAssertEqual(long, ToolNaming.sanitize(String(repeating: "a", count: 100)))
    }

    func testMCPImport() throws {
        let servers = try MCPServerConfig.importing(json: """
        {"mcpServers": {
          "fs": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"], "env": {"A": "1"}},
          "remote": {"url": "https://example.com/mcp", "headers": {"Authorization": "Bearer x"}}
        }}
        """)
        XCTAssertEqual(servers.map(\.name), ["fs", "remote"])
        XCTAssertEqual(servers[0].transport, .stdio(command: "npx", arguments: ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"], workingDirectory: nil))
        XCTAssertEqual(servers[0].environment["A"], "1")
        XCTAssertEqual(servers[1].headers["Authorization"], "Bearer x")
    }

    func testMCPToolOutput() {
        let output = MCPClient.output(from: ["content": [["type": "text", "text": "a"], ["type": "image", "data": "AAAA", "mimeType": "image/png"]], "isError": true])
        XCTAssertEqual(output.text, "a")
        XCTAssertEqual(output.images.count, 1)
        XCTAssertTrue(output.isError)
    }

    func testHTMLText() {
        let (title, text) = HTMLText.extract("<html><head><title>T &amp; U</title><style>x{}</style></head><body><p>Hello&nbsp;<b>world</b></p><script>bad()</script><p>&#x41;</p></body></html>")
        XCTAssertEqual(title, "T & U")
        XCTAssertTrue(text.contains("Hello world"))
        XCTAssertTrue(text.contains("A"))
        XCTAssertFalse(text.contains("bad()"))
    }

    func testSettingsRepositoryMovesMCPSecretsToKeychain() {
        final class Backend: SettingsBackend {
            var data: Data?
            func loadSettingsData() -> Data? { data }
            func saveSettingsData(_ data: Data) { self.data = data }
        }
        let backend = Backend()
        let secrets = InMemorySecretStore()
        let repository = SettingsRepository(backend: backend, secrets: secrets)
        var settings = DropChatSettings()
        settings.mcpServers = [MCPServerConfig(name: "x", transport: .http(url: "https://x"), headers: ["Authorization": "Bearer secret"])]
        repository.save(settings)

        let stored = String(decoding: backend.data ?? Data(), as: UTF8.self)
        XCTAssertFalse(stored.contains("secret"))
        XCTAssertEqual(repository.load().mcpServers.first?.headers["Authorization"], "Bearer secret")
    }

    func testJSONRoundTrip() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": "d"]]
        XCTAssertEqual(try JSONValue.parse(value.serialized()), value)
        XCTAssertEqual(JSONValue.number(3).serialized(), "3")
    }
}

final class ConcurrencyPrimitiveTests: XCTestCase {
    /// A SyncLock that built itself recursively crashed Droppy on activation.
    func testSyncLockConstructsAndGuards() {
        let lock = SyncLock()
        var counter = 0
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            lock.withLock { counter += 1 }
        }
        XCTAssertEqual(counter, 1_000)
        lock.lock()
        lock.unlock()
    }

    func testApprovalMemory() {
        let memory = ToolApprovalMemory()
        XCTAssertFalse(memory.contains("echo"))
        memory.remember("echo")
        XCTAssertTrue(memory.contains("echo"))
        memory.reset()
        XCTAssertFalse(memory.contains("echo"))
    }

    func testAllowForConversationIsRemembered() async throws {
        final class CountingApprovals: ApprovalHandler, @unchecked Sendable {
            let lock = SyncLock()
            var asked = 0
            func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
                lock.withLock { asked += 1 }
                return .allowForConversation
            }
        }
        let approvals = CountingApprovals()
        let memory = ToolApprovalMemory()
        let tool = FunctionTool(spec: ToolSpec(name: "echo", description: "", inputSchema: ["type": "object"]), sourceID: "test", approval: { _ in .ask(reason: "x") }) { _, _ in
            ToolOutput(text: "ok")
        }
        let provider = AgentLoopTests.ScriptedProvider(turns: [
            [.toolCall(ToolCall(id: "1", name: "echo", arguments: [:])), .finished(.toolUse)],
            [.toolCall(ToolCall(id: "2", name: "echo", arguments: [:])), .finished(.toolUse)],
        ])
        let loop = AgentLoop(provider: provider, model: "m", system: nil, tools: [tool], approvals: approvals, context: ToolContext(conversationID: UUID()), approvalMemory: memory)
        for try await _ in loop.run(transcript: [.user("go")]) {}
        XCTAssertEqual(approvals.asked, 1)
        XCTAssertTrue(memory.contains("echo"))
    }
}
