import Foundation

/// Anthropic's Messages API.
public struct AnthropicProvider: LLMProvider {
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let config: ProviderConfig
    let apiKey: String?
    let http: HTTPClient

    public init(config: ProviderConfig, apiKey: String?, http: HTTPClient) {
        self.config = config
        self.apiKey = apiKey
        self.http = http
    }

    func headers(betas: [String] = []) -> [String: String] {
        var headers = config.extraHeaders
        headers["x-api-key"] = apiKey ?? ""
        headers["anthropic-version"] = Self.apiVersion
        if !betas.isEmpty { headers["anthropic-beta"] = betas.joined(separator: ",") }
        return headers
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let provider = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = provider.apiKey, !key.isEmpty else {
                        throw ProviderError.missingAPIKey(provider.config.name)
                    }
                    let encoder = AnthropicEncoder(config: provider.config)
                    let url = try makeURL(provider.config.normalizedBaseURL + "/v1/messages")
                    let urlRequest = URLRequest.jsonPost(
                        url,
                        body: encoder.body(for: request),
                        headers: provider.headers(betas: encoder.betas(for: request))
                    )
                    var decoder = AnthropicStreamDecoder()
                    for try await event in try await provider.http.lines(urlRequest).sseEvents() {
                        for output in try decoder.feed(event) { continuation.yield(output) }
                    }
                    for output in decoder.finish() { continuation.yield(output) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        let url = try makeURL(config.normalizedBaseURL + "/v1/models?limit=1000")
        let (data, _) = try await http.send(.get(url, headers: headers()))
        let json = try JSONValue.parse(data)
        return (json["data"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["id"]?.stringValue else { return nil }
            return ModelInfo(id: id, displayName: item["display_name"]?.stringValue)
        }
    }
}

public struct AnthropicEncoder: Sendable {
    public let config: ProviderConfig

    public init(config: ProviderConfig) { self.config = config }

    /// Models that accept `fallbacks: "default"`.
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    func usesFallback(_ model: String) -> Bool {
        config.refusalFallbackEnabled
            && config.normalizedBaseURL == ProviderKind.anthropic.defaultBaseURL
            && Self.fallbackModels.contains(model)
    }

    /// Adaptive thinking is available on every current model except the
    /// Haiku 4.5 generation and older 3.x models.
    func supportsAdaptiveThinking(_ model: String) -> Bool {
        !(model.contains("claude-3") || model.contains("haiku-4"))
    }

    public func betas(for request: ChatRequest) -> [String] {
        usesFallback(request.model) ? [AnthropicProvider.fallbackBeta] : []
    }

    public func body(for request: ChatRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(config.maxOutputTokens ?? 64_000)),
            "stream": true,
            "messages": .array(messages(for: request.messages)),
        ]
        if let system = request.system, !system.isEmpty {
            body["system"] = .string(system)
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.inputSchema,
                    // Stream large inputs as they are written; the decoder
                    // validates the JSON before the tool runs.
                    "eager_input_streaming": true,
                ]
            })
        }
        if config.reasoningEnabled, supportsAdaptiveThinking(request.model) {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        if usesFallback(request.model) {
            body["fallbacks"] = "default"
        }
        // No temperature: the current API version rejects sampling parameters.
        return .object(body)
    }

    func messages(for messages: [ChatMessage]) -> [JSONValue] {
        var output: [JSONValue] = []
        for message in messages {
            let blocks = message.parts.compactMap(block(for:))
            guard !blocks.isEmpty else { continue }
            output.append(["role": .string(message.role.rawValue), "content": .array(blocks)])
        }
        return output
    }

    func block(for part: ContentPart) -> JSONValue? {
        switch part {
        case .text(let text):
            guard !text.isEmpty else { return nil }
            return ["type": "text", "text": .string(text)]
        case .image(let image):
            return ["type": "image", "source": ["type": "base64", "media_type": .string(image.mediaType), "data": .string(image.base64)]]
        case .document(let document):
            if let data = document.data, data.mediaType == "application/pdf" {
                return [
                    "type": "document",
                    "title": .string(document.filename),
                    "source": ["type": "base64", "media_type": "application/pdf", "data": .string(data.base64)],
                ]
            }
            return ["type": "text", "text": .string(DocumentText.render(document))]
        case .reasoning(let reasoning):
            guard reasoning.providerKind == .anthropic else { return nil }
            if let redacted = reasoning.redactedData {
                return ["type": "redacted_thinking", "data": .string(redacted)]
            }
            guard let signature = reasoning.signature else { return nil }
            return ["type": "thinking", "thinking": .string(reasoning.text), "signature": .string(signature)]
        case .toolCall(let call):
            return ["type": "tool_use", "id": .string(call.id), "name": .string(call.name), "input": call.arguments]
        case .toolResult(let result):
            var content: [JSONValue] = []
            if !result.text.isEmpty { content.append(["type": "text", "text": .string(result.text)]) }
            for image in result.images {
                content.append(["type": "image", "source": ["type": "base64", "media_type": .string(image.mediaType), "data": .string(image.base64)]])
            }
            if content.isEmpty { content.append(["type": "text", "text": "(no output)"]) }
            return [
                "type": "tool_result",
                "tool_use_id": .string(result.callID),
                "content": .array(content),
                "is_error": .bool(result.isError),
            ]
        }
    }
}

/// Decodes Messages API SSE events.
public struct AnthropicStreamDecoder: Sendable {
    enum Block: Sendable {
        case text
        case thinking(text: String, signature: String?)
        case redacted(String)
        case toolUse(id: String, name: String, json: String)
        case other
    }

    private var blocks: [Int: Block] = [:]
    private var stopReason: StopReason?
    private var refusalExplanation: String?
    private var finished = false

    public init() {}

    public mutating func feed(_ event: SSEEvent) throws -> [StreamEvent] {
        guard let json = try? JSONValue.parse(event.data) else { return [] }
        let type = json["type"]?.stringValue ?? event.event ?? ""
        switch type {
        case "message_start":
            var output: [StreamEvent] = []
            if let model = json["message"]?["model"]?.stringValue { output.append(.modelInfo(model)) }
            if let usage = json["message"]?["usage"] {
                output.append(.usage(TokenUsage(inputTokens: usage["input_tokens"]?.intValue ?? 0, outputTokens: 0)))
            }
            return output

        case "content_block_start":
            let index = json["index"]?.intValue ?? 0
            let block = json["content_block"] ?? .null
            switch block["type"]?.stringValue {
            case "text":
                blocks[index] = .text
                if let text = block["text"]?.stringValue, !text.isEmpty { return [.textDelta(text)] }
            case "thinking":
                blocks[index] = .thinking(text: block["thinking"]?.stringValue ?? "", signature: block["signature"]?.stringValue)
            case "redacted_thinking":
                blocks[index] = .redacted(block["data"]?.stringValue ?? "")
            case "tool_use":
                blocks[index] = .toolUse(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "", json: "")
            case "fallback":
                blocks[index] = .other
                return [.fallbackBoundary(fromModel: block["from"]?["model"]?.stringValue, toModel: block["to"]?["model"]?.stringValue)]
            default:
                blocks[index] = .other
            }
            return []

        case "content_block_delta":
            let index = json["index"]?.intValue ?? 0
            let delta = json["delta"] ?? .null
            switch (delta["type"]?.stringValue, blocks[index]) {
            case ("text_delta", _):
                return [.textDelta(delta["text"]?.stringValue ?? "")]
            case ("thinking_delta", .thinking(let text, let signature)?):
                let piece = delta["thinking"]?.stringValue ?? ""
                blocks[index] = .thinking(text: text + piece, signature: signature)
                return piece.isEmpty ? [] : [.reasoningDelta(piece)]
            case ("signature_delta", .thinking(let text, let signature)?):
                blocks[index] = .thinking(text: text, signature: (signature ?? "") + (delta["signature"]?.stringValue ?? ""))
                return []
            case ("input_json_delta", .toolUse(let id, let name, let partial)?):
                blocks[index] = .toolUse(id: id, name: name, json: partial + (delta["partial_json"]?.stringValue ?? ""))
                return []
            default:
                return []
            }

        case "content_block_stop":
            let index = json["index"]?.intValue ?? 0
            defer { blocks[index] = nil }
            switch blocks[index] {
            case .thinking(let text, let signature)?:
                return [.reasoningBlock(ReasoningContent(providerKind: .anthropic, text: text, signature: signature))]
            case .redacted(let data)?:
                return [.reasoningBlock(ReasoningContent(providerKind: .anthropic, text: "", redactedData: data))]
            case .toolUse(let id, let name, let partial)?:
                return [.toolCall(ToolArguments.makeCall(id: id, name: name, json: partial))]
            default:
                return []
            }

        case "message_delta":
            var output: [StreamEvent] = []
            if let reason = json["delta"]?["stop_reason"]?.stringValue {
                stopReason = Self.stopReason(reason, details: json["delta"]?["stop_details"])
            }
            if let usage = json["usage"], let outputTokens = usage["output_tokens"]?.intValue {
                output.append(.usage(TokenUsage(inputTokens: 0, outputTokens: outputTokens)))
            }
            return output

        case "message_stop":
            return finish()

        case "error":
            throw ProviderError.api(json["error"]?["message"]?.stringValue ?? "The API reported an error.")

        default:
            return []
        }
    }

    public mutating func finish() -> [StreamEvent] {
        guard !finished else { return [] }
        finished = true
        return [.finished(stopReason ?? .endTurn)]
    }

    static func stopReason(_ raw: String, details: JSONValue?) -> StopReason {
        switch raw {
        case "end_turn", "stop_sequence", "pause_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens", "model_context_window_exceeded": return .maxTokens
        case "refusal": return .refusal(details?["explanation"]?.stringValue)
        default: return .other(raw)
        }
    }
}
