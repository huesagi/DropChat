import Foundation

/// Who wrote a message. The system prompt is not a message: it is built per
/// request by `SystemPromptBuilder` and handed to the provider separately.
/// Tool results travel in `.user` messages, as Anthropic models them; each
/// provider's encoder maps them onto its own wire shape.
public enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}

/// Binary content carried inline (images, PDFs).
public struct InlineData: Codable, Hashable, Sendable {
    public var mediaType: String
    public var base64: String

    public init(mediaType: String, base64: String) {
        self.mediaType = mediaType
        self.base64 = base64
    }

    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.base64 = data.base64EncodedString()
    }

    public var dataURL: String { "data:\(mediaType);base64,\(base64)" }
}

/// A document the user attached. Providers that read the format natively get
/// `data`; every other provider gets `extractedText`.
public struct DocumentContent: Codable, Hashable, Sendable {
    public var filename: String
    public var data: InlineData?
    public var extractedText: String?

    public init(filename: String, data: InlineData?, extractedText: String?) {
        self.filename = filename
        self.data = data
        self.extractedText = extractedText
    }
}

/// One tool invocation requested by the model.
public struct ToolCall: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The parsed input. `.object` for every well-formed call.
    public var arguments: JSONValue
    /// Set when the model's argument JSON did not parse; the agent loop turns
    /// it into an error result instead of running the tool.
    public var argumentError: String?
    /// Opaque provider data that must be echoed back (Gemini thought signatures).
    public var providerMetadata: [String: String]?

    public init(id: String, name: String, arguments: JSONValue, argumentError: String? = nil, providerMetadata: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.argumentError = argumentError
        self.providerMetadata = providerMetadata
    }
}

/// What a tool returned.
public struct ToolResult: Codable, Hashable, Sendable {
    public var callID: String
    public var toolName: String
    public var text: String
    public var images: [InlineData]
    public var isError: Bool

    public init(callID: String, toolName: String, text: String, images: [InlineData] = [], isError: Bool = false) {
        self.callID = callID
        self.toolName = toolName
        self.text = text
        self.images = images
        self.isError = isError
    }
}

/// Model reasoning. Anthropic requires thinking blocks to be echoed back
/// unchanged (with their signature) inside a tool loop, so they are stored
/// rather than only displayed.
public struct ReasoningContent: Codable, Hashable, Sendable {
    /// Which provider produced it. Reasoning is only replayed to the provider
    /// kind that wrote it.
    public var providerKind: ProviderKind
    public var text: String
    public var signature: String?
    /// `redacted_thinking` payload, when the block was redacted.
    public var redactedData: String?

    public init(providerKind: ProviderKind, text: String, signature: String? = nil, redactedData: String? = nil) {
        self.providerKind = providerKind
        self.text = text
        self.signature = signature
        self.redactedData = redactedData
    }
}

public enum ContentPart: Codable, Hashable, Sendable {
    case text(String)
    case image(InlineData)
    case document(DocumentContent)
    case reasoning(ReasoningContent)
    case toolCall(ToolCall)
    case toolResult(ToolResult)

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

public struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var role: ChatRole
    public var parts: [ContentPart]
    public var createdAt: Date
    /// The model that produced an assistant message.
    public var model: String?
    /// Set when generation ended abnormally (refusal, error, cancellation).
    public var notice: String?

    public init(id: UUID = UUID(), role: ChatRole, parts: [ContentPart], createdAt: Date = Date(), model: String? = nil, notice: String? = nil) {
        self.id = id
        self.role = role
        self.parts = parts
        self.createdAt = createdAt
        self.model = model
        self.notice = notice
    }

    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, parts: [.text(text)])
    }

    /// Concatenated visible text.
    public var plainText: String {
        parts.compactMap(\.text).joined(separator: "\n\n")
    }

    public var toolCalls: [ToolCall] {
        parts.compactMap { if case .toolCall(let call) = $0 { return call } else { return nil } }
    }

    public var toolResults: [ToolResult] {
        parts.compactMap { if case .toolResult(let result) = $0 { return result } else { return nil } }
    }

    /// A user message that only carries tool results (not shown as a bubble).
    public var isToolResultCarrier: Bool {
        role == .user && !parts.isEmpty && parts.allSatisfy {
            if case .toolResult = $0 { return true } else { return false }
        }
    }
}

public struct Conversation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var providerID: String?
    public var model: String?

    public init(id: UUID = UUID(), title: String = "New chat", messages: [ChatMessage] = [], createdAt: Date = Date(), updatedAt: Date = Date(), providerID: String? = nil, model: String? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerID = providerID
        self.model = model
    }
}

/// A tool as offered to the model.
public struct ToolSpec: Codable, Hashable, Sendable {
    /// Unique, provider-safe name (`^[a-zA-Z0-9_-]{1,64}$`).
    public var name: String
    public var description: String
    /// JSON Schema of the input object.
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct TokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }
}
