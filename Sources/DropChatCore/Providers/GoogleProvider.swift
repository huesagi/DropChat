import Foundation

/// Google's Gemini API (`generateContent`).
public struct GoogleProvider: LLMProvider {
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
        headers["x-goog-api-key"] = apiKey ?? ""
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
                    let model = request.model.hasPrefix("models/") ? String(request.model.dropFirst(7)) : request.model
                    let url = try makeURL(provider.config.normalizedBaseURL + "/models/\(model):streamGenerateContent?alt=sse")
                    let body = GeminiEncoder(config: provider.config).body(for: request)
                    var decoder = GeminiStreamDecoder()
                    for try await event in try await provider.http.lines(.jsonPost(url, body: body, headers: provider.headers)).sseEvents() {
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
        let url = try makeURL(config.normalizedBaseURL + "/models?pageSize=1000")
        let (data, _) = try await http.send(.get(url, headers: headers))
        let json = try JSONValue.parse(data)
        return (json["models"]?.arrayValue ?? []).compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            let methods = item["supportedGenerationMethods"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard methods.isEmpty || methods.contains("generateContent") else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
            return ModelInfo(id: id, displayName: item["displayName"]?.stringValue)
        }
    }
}

public struct GeminiEncoder: Sendable {
    public let config: ProviderConfig
    public static let signatureKey = "thoughtSignature"

    public init(config: ProviderConfig) { self.config = config }

    public func body(for request: ChatRequest) -> JSONValue {
        var body: [String: JSONValue] = ["contents": .array(contents(for: request.messages))]
        if let system = request.system, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": .string(system)]]]
        }
        if !request.tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": .array(request.tools.map { tool in
                    [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        // The JSON Schema field takes full schemas, unlike the
                        // OpenAPI-subset `parameters`.
                        "parametersJsonSchema": tool.inputSchema,
                    ]
                }),
            ]]
        }
        var generation: [String: JSONValue] = [:]
        if let maxTokens = config.maxOutputTokens { generation["maxOutputTokens"] = .number(Double(maxTokens)) }
        if let temperature = config.temperature { generation["temperature"] = .number(temperature) }
        if config.reasoningEnabled { generation["thinkingConfig"] = ["includeThoughts": true] }
        if !generation.isEmpty { body["generationConfig"] = .object(generation) }
        return .object(body)
    }

    func contents(for messages: [ChatMessage]) -> [JSONValue] {
        messages.compactMap { message -> JSONValue? in
            let parts = message.parts.compactMap(part(for:))
            guard !parts.isEmpty else { return nil }
            return ["role": message.role == .assistant ? "model" : "user", "parts": .array(parts)]
        }
    }

    func part(for part: ContentPart) -> JSONValue? {
        switch part {
        case .text(let text):
            return text.isEmpty ? nil : ["text": .string(text)]
        case .image(let image):
            return ["inlineData": ["mimeType": .string(image.mediaType), "data": .string(image.base64)]]
        case .document(let document):
            if let data = document.data, data.mediaType == "application/pdf" {
                return ["inlineData": ["mimeType": "application/pdf", "data": .string(data.base64)]]
            }
            return ["text": .string(DocumentText.render(document))]
        case .reasoning:
            // Gemini carries its reasoning state in thought signatures on the
            // function call parts; thought summaries are not sent back.
            return nil
        case .toolCall(let call):
            var value: [String: JSONValue] = ["functionCall": ["name": .string(call.name), "args": call.arguments]]
            if let signature = call.providerMetadata?[Self.signatureKey] {
                value[Self.signatureKey] = .string(signature)
            }
            return .object(value)
        case .toolResult(let result):
            var response: [String: JSONValue] = [result.isError ? "error" : "result": .string(result.text)]
            if !result.images.isEmpty { response["note"] = .string("\(result.images.count) image(s) omitted") }
            return ["functionResponse": ["name": .string(result.toolName), "response": .object(response)]]
        }
    }
}

public struct GeminiStreamDecoder: Sendable {
    private var calls: [ToolCall] = []
    private var finishReason: String?
    private var finished = false
    private var reportedModel = false
    private var callCounter = 0

    public init() {}

    public mutating func feed(_ event: SSEEvent) throws -> [StreamEvent] {
        guard let json = try? JSONValue.parse(event.data) else { return [] }
        if let error = json["error"] {
            throw ProviderError.api(error["message"]?.stringValue ?? error.serialized())
        }
        var output: [StreamEvent] = []
        if !reportedModel, let model = json["modelVersion"]?.stringValue {
            reportedModel = true
            output.append(.modelInfo(model))
        }
        if let usage = json["usageMetadata"], let prompt = usage["promptTokenCount"]?.intValue {
            // Gemini repeats cumulative usage on every chunk; keep only the
            // last by reporting it from finish().
            lastUsage = TokenUsage(
                inputTokens: prompt,
                outputTokens: (usage["candidatesTokenCount"]?.intValue ?? 0) + (usage["thoughtsTokenCount"]?.intValue ?? 0)
            )
        }
        guard let candidate = json["candidates"]?[0] else {
            if let block = json["promptFeedback"]?["blockReason"]?.stringValue {
                finishReason = "BLOCKED:\(block)"
            }
            return output
        }
        for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
            if let call = part["functionCall"] {
                callCounter += 1
                var metadata: [String: String]?
                if let signature = part[GeminiEncoder.signatureKey]?.stringValue {
                    metadata = [GeminiEncoder.signatureKey: signature]
                }
                let id = call["id"]?.stringValue ?? "gemini_call_\(callCounter)"
                let arguments = call["args"] ?? .object([:])
                calls.append(ToolCall(id: id, name: call["name"]?.stringValue ?? "", arguments: arguments.objectValue == nil ? .object([:]) : arguments, providerMetadata: metadata))
            } else if let text = part["text"]?.stringValue, !text.isEmpty {
                if part["thought"]?.boolValue == true {
                    output.append(.reasoningDelta(text))
                } else {
                    output.append(.textDelta(text))
                }
            }
        }
        if let reason = candidate["finishReason"]?.stringValue {
            finishReason = reason
        }
        return output
    }

    private var lastUsage: TokenUsage?

    public mutating func finish() -> [StreamEvent] {
        guard !finished else { return [] }
        finished = true
        var output: [StreamEvent] = calls.map { .toolCall($0) }
        if let lastUsage { output.append(.usage(lastUsage)) }
        let stop: StopReason
        switch finishReason {
        case _ where !calls.isEmpty: stop = .toolUse
        case "STOP", nil: stop = .endTurn
        case "MAX_TOKENS": stop = .maxTokens
        case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION":
            stop = .refusal("Gemini stopped the response (\(finishReason ?? "safety")).")
        case let reason? where reason.hasPrefix("BLOCKED:"):
            stop = .refusal("Gemini blocked the prompt (\(reason.dropFirst(8))).")
        case let reason?: stop = .other(reason)
        }
        output.append(.finished(stop))
        return output
    }
}
