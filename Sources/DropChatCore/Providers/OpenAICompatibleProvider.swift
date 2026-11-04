import Foundation

/// OpenAI Chat Completions, which OpenAI, OpenRouter and most self-hosted
/// servers (Ollama, LM Studio, vLLM, llama.cpp) speak.
public struct OpenAICompatibleProvider: LLMProvider {
    public let config: ProviderConfig
    let apiKey: String?
    let http: HTTPClient

    public init(config: ProviderConfig, apiKey: String?, http: HTTPClient) {
        self.config = config
        self.apiKey = apiKey
        self.http = http
    }

    var headers: [String: String] {
        var headers = config.extraHeaders
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        if config.kind == .openRouter {
            headers["HTTP-Referer"] = headers["HTTP-Referer"] ?? "https://github.com/huesagi/DropChat"
            headers["X-Title"] = headers["X-Title"] ?? "DropChat"
        }
        return headers
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let config = self.config
        let headers = self.headers
        let http = self.http
        let apiKey = self.apiKey
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if config.kind.requiresAPIKey, (apiKey ?? "").isEmpty {
                        throw ProviderError.missingAPIKey(config.name)
                    }
                    let url = try makeURL(config.normalizedBaseURL + "/chat/completions")
                    let body = OpenAIChatEncoder(config: config).body(for: request)
                    var urlRequest = URLRequest.jsonPost(url, body: body, headers: headers)
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    var decoder = OpenAIChatStreamDecoder()
                    for try await event in try await http.lines(urlRequest).sseEvents() {
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
        let url = try makeURL(config.normalizedBaseURL + "/models")
        let (data, _) = try await http.send(.get(url, headers: headers))
        let json = try JSONValue.parse(data)
        let models = (json["data"]?.arrayValue ?? []).compactMap { item -> ModelInfo? in
            guard let id = item["id"]?.stringValue else { return nil }
            return ModelInfo(id: id, displayName: item["name"]?.stringValue)
        }
        return models.sorted { $0.id < $1.id }
    }
}

/// Builds a Chat Completions request body.
public struct OpenAIChatEncoder: Sendable {
    public let config: ProviderConfig

    public init(config: ProviderConfig) { self.config = config }

    public func body(for request: ChatRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": true,
            "messages": .array(messages(for: request)),
        ]
        if config.kind != .openAICompatible {
            body["stream_options"] = ["include_usage": true]
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                    ],
                ]
            })
        }
        if let maxTokens = config.maxOutputTokens {
            body[config.kind == .openAI ? "max_completion_tokens" : "max_tokens"] = .number(Double(maxTokens))
        }
        if let temperature = config.temperature {
            body["temperature"] = .number(temperature)
        }
        if config.kind == .openRouter, config.reasoningEnabled {
            body["reasoning"] = ["enabled": true]
        }
        return .object(body)
    }

    func messages(for request: ChatRequest) -> [JSONValue] {
        var output: [JSONValue] = []
        if let system = request.system, !system.isEmpty {
            output.append(["role": "system", "content": .string(system)])
        }
        for message in request.messages {
            switch message.role {
            case .assistant:
                var entry: [String: JSONValue] = ["role": "assistant"]
                let text = message.plainText
                entry["content"] = text.isEmpty ? .null : .string(text)
                let calls = message.toolCalls
                if !calls.isEmpty {
                    entry["tool_calls"] = .array(calls.map { call in
                        [
                            "id": .string(call.id),
                            "type": "function",
                            "function": [
                                "name": .string(call.name),
                                "arguments": .string(call.arguments.serialized()),
                            ],
                        ]
                    })
                }
                output.append(.object(entry))
            case .user:
                // Tool results become `tool` messages, which must directly
                // follow the assistant message that asked for them.
                for result in message.toolResults {
                    var text = result.text
                    if !result.images.isEmpty {
                        text += "\n[\(result.images.count) image(s) returned by the tool are attached below]"
                    }
                    output.append(["role": "tool", "tool_call_id": .string(result.callID), "content": .string(text)])
                }
                let toolImages = message.toolResults.flatMap(\.images)
                var content = contentParts(for: message.parts)
                content += toolImages.map { image in ["type": "image_url", "image_url": ["url": .string(image.dataURL)]] }
                if !content.isEmpty {
                    // Plain string content is the most widely accepted shape.
                    if content.count == 1, let only = content.first, only["type"]?.stringValue == "text" {
                        output.append(["role": "user", "content": only["text"] ?? ""])
                    } else {
                        output.append(["role": "user", "content": .array(content)])
                    }
                }
            }
        }
        return output
    }

    func contentParts(for parts: [ContentPart]) -> [JSONValue] {
        parts.compactMap { part -> JSONValue? in
            switch part {
            case .text(let text):
                return ["type": "text", "text": .string(text)]
            case .image(let image):
                return ["type": "image_url", "image_url": ["url": .string(image.dataURL)]]
            case .document(let document):
                if config.kind.readsPDFNatively, let data = document.data, data.mediaType == "application/pdf" {
                    return ["type": "file", "file": ["filename": .string(document.filename), "file_data": .string(data.dataURL)]]
                }
                return ["type": "text", "text": .string(DocumentText.render(document))]
            case .reasoning, .toolCall, .toolResult:
                return nil
            }
        }
    }
}

/// Decodes Chat Completions SSE chunks. Tool call arguments arrive in pieces
/// keyed by `index` and are emitted whole when the choice finishes.
public struct OpenAIChatStreamDecoder: Sendable {
    struct PartialCall: Sendable {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    private var calls: [Int: PartialCall] = [:]
    private var finishReason: String?
    private var finished = false
    private var reportedModel = false

    public init() {}

    public mutating func feed(_ event: SSEEvent) throws -> [StreamEvent] {
        let data = event.data.trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" { return finish() }
        guard let json = try? JSONValue.parse(data) else { return [] }
        if let error = json["error"] {
            throw ProviderError.api(error["message"]?.stringValue ?? error.serialized())
        }

        var output: [StreamEvent] = []
        if !reportedModel, let model = json["model"]?.stringValue, !model.isEmpty {
            reportedModel = true
            output.append(.modelInfo(model))
        }
        if let usage = json["usage"], !usage.isNull {
            output.append(.usage(TokenUsage(
                inputTokens: usage["prompt_tokens"]?.intValue ?? 0,
                outputTokens: usage["completion_tokens"]?.intValue ?? 0
            )))
        }
        guard let choice = json["choices"]?[0] else { return output }
        let delta = choice["delta"] ?? choice["message"] ?? .null

        for key in ["reasoning", "reasoning_content"] {
            if let reasoning = delta[key]?.stringValue, !reasoning.isEmpty {
                output.append(.reasoningDelta(reasoning))
            }
        }
        if let text = delta["content"]?.stringValue, !text.isEmpty {
            output.append(.textDelta(text))
        }
        for item in delta["tool_calls"]?.arrayValue ?? [] {
            let index = item["index"]?.intValue ?? calls.count
            var call = calls[index] ?? PartialCall()
            if let id = item["id"]?.stringValue, !id.isEmpty { call.id = id }
            if let name = item["function"]?["name"]?.stringValue { call.name += name }
            if let arguments = item["function"]?["arguments"]?.stringValue { call.arguments += arguments }
            calls[index] = call
        }
        if let reason = choice["finish_reason"]?.stringValue {
            finishReason = reason
        }
        return output
    }

    public mutating func finish() -> [StreamEvent] {
        guard !finished else { return [] }
        finished = true
        var output: [StreamEvent] = calls.keys.sorted().compactMap { index in
            guard let partial = calls[index], !partial.name.isEmpty else { return nil }
            let id = partial.id.isEmpty ? "call_\(index)_\(UUID().uuidString.prefix(8))" : partial.id
            return .toolCall(ToolArguments.makeCall(id: id, name: partial.name, json: partial.arguments))
        }
        let stop: StopReason
        switch finishReason {
        case "tool_calls", "function_call": stop = .toolUse
        case "length": stop = .maxTokens
        case "content_filter": stop = .refusal("The provider's content filter stopped the response.")
        case "stop", nil: stop = calls.isEmpty ? .endTurn : .toolUse
        case let other?: stop = .other(other)
        }
        output.append(.finished(stop))
        return output
    }
}

/// Shared parsing of streamed tool arguments.
public enum ToolArguments {
    public static func makeCall(id: String, name: String, json: String, metadata: [String: String]? = nil) -> ToolCall {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ToolCall(id: id, name: name, arguments: .object([:]), providerMetadata: metadata)
        }
        do {
            let value = try JSONValue.parse(trimmed)
            guard case .object = value else {
                return ToolCall(id: id, name: name, arguments: .object([:]), argumentError: "The arguments were not a JSON object.", providerMetadata: metadata)
            }
            return ToolCall(id: id, name: name, arguments: value, providerMetadata: metadata)
        } catch {
            return ToolCall(id: id, name: name, arguments: .object([:]), argumentError: "The arguments were not valid JSON (they may have been cut off).", providerMetadata: metadata)
        }
    }
}

/// How a document is shown to a model that cannot read its bytes.
public enum DocumentText {
    public static func render(_ document: DocumentContent) -> String {
        let body = document.extractedText ?? "(DropChat could not extract text from this file.)"
        return "<attachment name=\"\(document.filename)\">\n\(body)\n</attachment>"
    }
}
