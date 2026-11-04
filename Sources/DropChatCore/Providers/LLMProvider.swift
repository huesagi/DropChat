import Foundation

/// The wire protocol family a provider speaks, plus the presets built on it.
///
/// Adding a service that speaks the OpenAI Chat Completions protocol needs
/// only a new case and its metadata below; `ProviderFactory` maps it onto
/// `OpenAICompatibleProvider`. A service with its own protocol needs a new
/// `LLMProvider` implementation registered in `ProviderFactory`.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case openAI
    case anthropic
    case google
    case openRouter
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .openAICompatible: return "Custom endpoint"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .google: return "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAICompatible: return "http://localhost:11434/v1"
        }
    }

    /// Models offered before the live list has been fetched.
    public var suggestedModels: [String] {
        switch self {
        case .openAI: return ["gpt-5", "gpt-5-mini"]
        case .anthropic: return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
        case .google: return ["gemini-2.5-pro", "gemini-2.5-flash"]
        case .openRouter: return ["anthropic/claude-opus-5-5", "openai/gpt-5", "google/gemini-2.5-pro"]
        case .openAICompatible: return []
        }
    }

    public var requiresAPIKey: Bool { self != .openAICompatible }

    /// The wire protocol.
    public var wireFormat: WireFormat {
        switch self {
        case .openAI, .openRouter, .openAICompatible: return .openAIChat
        case .anthropic: return .anthropicMessages
        case .google: return .geminiGenerateContent
        }
    }

    /// Whether the API reads PDF bytes natively. Others get extracted text.
    public var readsPDFNatively: Bool {
        switch self {
        case .openAI, .openRouter, .anthropic, .google: return true
        case .openAICompatible: return false
        }
    }
}

public enum WireFormat: String, Codable, Sendable {
    case openAIChat
    case anthropicMessages
    case geminiGenerateContent
}

/// A configured provider account. The API key is not stored here: it lives
/// in the Keychain under `ProviderConfig.secretAccount`.
public struct ProviderConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ProviderKind
    public var name: String
    public var baseURL: String
    public var defaultModel: String
    /// Models the user pinned to the picker (in addition to the live list).
    public var pinnedModels: [String]
    public var extraHeaders: [String: String]
    public var maxOutputTokens: Int?
    public var temperature: Double?
    /// Ask the model to reason before answering, where the API supports it.
    public var reasoningEnabled: Bool
    /// Anthropic only: server-side refusal fallback (`fallbacks: "default"`).
    public var refusalFallbackEnabled: Bool
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        kind: ProviderKind,
        name: String? = nil,
        baseURL: String? = nil,
        defaultModel: String? = nil,
        pinnedModels: [String] = [],
        extraHeaders: [String: String] = [:],
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        reasoningEnabled: Bool = true,
        refusalFallbackEnabled: Bool = true,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.displayName
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.defaultModel = defaultModel ?? kind.suggestedModels.first ?? ""
        self.pinnedModels = pinnedModels
        self.extraHeaders = extraHeaders
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.reasoningEnabled = reasoningEnabled
        self.refusalFallbackEnabled = refusalFallbackEnabled
        self.isEnabled = isEnabled
    }

    public var secretAccount: String { "provider.\(id)" }

    /// `baseURL` with any trailing slash removed.
    public var normalizedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}

/// Everything a provider needs for one model call.
public struct ChatRequest: Sendable {
    public var model: String
    public var system: String?
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]

    public init(model: String, system: String?, messages: [ChatMessage], tools: [ToolSpec]) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
    }
}

public enum StopReason: Hashable, Sendable {
    case endTurn
    case toolUse
    case maxTokens
    case refusal(String?)
    case other(String)
}

/// Incremental output of one model call.
public enum StreamEvent: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    /// A finished reasoning block (with its signature) to store for replay.
    case reasoningBlock(ReasoningContent)
    /// A complete tool call, emitted once its arguments are fully streamed.
    case toolCall(ToolCall)
    /// The server switched to a fallback model mid-response. Reasoning and
    /// tool calls received before this point must not be echoed back.
    case fallbackBoundary(fromModel: String?, toModel: String?)
    case usage(TokenUsage)
    case modelInfo(String)
    case finished(StopReason)
}

public struct ModelInfo: Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
    }
}

public enum ProviderError: LocalizedError, Sendable {
    case missingAPIKey(String)
    case invalidURL(String)
    case http(status: Int, message: String)
    case api(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name): return "Add an API key for \(name) in DropChat's settings."
        case .invalidURL(let url): return "The address \(url) is not a valid URL."
        case .http(let status, let message): return "The server answered \(status): \(message)"
        case .api(let message): return message
        case .decoding(let message): return "The response could not be read: \(message)"
        }
    }
}

/// One LLM API. Implementations are stateless value types; a call's state
/// lives in its stream.
public protocol LLMProvider: Sendable {
    var config: ProviderConfig { get }

    /// Streams one model turn. Cancelling the consuming task cancels the request.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>

    /// The models this account can use.
    func listModels() async throws -> [ModelInfo]
}
