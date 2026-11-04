import Foundation

/// A tool source the settings call for, with a fingerprint of the
/// configuration it was built from. The engine rebuilds a source only when
/// its fingerprint changes, so editing one MCP server does not restart the
/// others.
public struct ToolSourceSpec {
    public var id: String
    public var fingerprint: String
    public var make: () -> any ToolSource

    public init(id: String, fingerprint: String, make: @escaping () -> any ToolSource) {
        self.id = id
        self.fingerprint = fingerprint
        self.make = make
    }
}

/// Turns settings into tool sources. Register one per feature family.
public typealias ToolSourceBuilder = (DropChatSettings, SecretStore, HTTPClient) -> [ToolSourceSpec]

public enum BuiltInToolSources {
    public static let all: [ToolSourceBuilder] = [mcp, web, skills]

    public static let mcp: ToolSourceBuilder = { settings, _, _ in
        settings.mcpServers.filter(\.isEnabled).map { server in
            ToolSourceSpec(id: "mcp.\(server.id)", fingerprint: (try? JSONEncoder().encode(server)).map { String(decoding: $0, as: UTF8.self) } ?? server.id) {
                MCPToolSource(config: server)
            }
        }
    }

    public static let web: ToolSourceBuilder = { settings, secrets, http in
        guard settings.web.isEnabled else { return [] }
        let exaKey = secrets.read(WebBackend.exa.secretAccount) ?? ""
        let perplexityKey = secrets.read(WebBackend.perplexity.secretAccount) ?? ""
        let searcher: (any WebSearchProvider)?
        switch settings.web.searchBackend {
        case .exa: searcher = exaKey.isEmpty ? nil : ExaProvider(apiKey: exaKey, http: http)
        case .perplexity: searcher = perplexityKey.isEmpty ? nil : PerplexityProvider(apiKey: perplexityKey, mode: settings.web.perplexityMode, http: http)
        }
        let fetcher: any WebFetchProvider = settings.web.useExaForFetching && !exaKey.isEmpty
            ? ExaProvider(apiKey: exaKey, http: http)
            : BasicWebFetcher(http: http)
        // Keys enter the in-memory fingerprint only as a hash.
        let fingerprint = "\(settings.web.hashValue)|\(exaKey.hashValue)|\(perplexityKey.hashValue)"
        return [ToolSourceSpec(id: "web", fingerprint: fingerprint) { WebToolSource(searcher: searcher, fetcher: fetcher) }]
    }

    public static let skills: ToolSourceBuilder = { settings, _, _ in
        guard settings.skills.isEnabled, !settings.skills.directories.isEmpty else { return [] }
        let fingerprint = "\(settings.skills.directories.joined(separator: "|"))|\(settings.skills.allowsScripts)"
        return [ToolSourceSpec(id: "skills", fingerprint: fingerprint) {
            SkillToolSource(directories: settings.skills.directoryURLs, allowsScripts: settings.skills.allowsScripts)
        }]
    }
}

public enum ChatEngineError: LocalizedError {
    case noProvider
    case noModel

    public var errorDescription: String? {
        switch self {
        case .noProvider: return "Add a provider in DropChat's settings to start chatting."
        case .noModel: return "Choose a model for this provider in DropChat's settings."
        }
    }
}

/// The engine behind every chat surface: providers, tools and prompts,
/// rebuilt from settings. Foundation-only, so it is testable without Droppy.
public final class ChatEngine: @unchecked Sendable {
    public let registry = ToolRegistry()
    public let http: HTTPClient
    public let secrets: SecretStore
    public let providers: ProviderFactory
    private let builders: [ToolSourceBuilder]

    private let lock = SyncLock()
    private var fingerprints: [String: String] = [:]

    public init(secrets: SecretStore, http: HTTPClient = URLSessionHTTPClient(), builders: [ToolSourceBuilder] = BuiltInToolSources.all) {
        self.secrets = secrets
        self.http = http
        self.providers = ProviderFactory(http: http)
        self.builders = builders
    }

    /// Brings the running tool sources in line with `settings`.
    public func apply(_ settings: DropChatSettings) async {
        let specs = builders.flatMap { $0(settings, secrets, http) }
        let wanted = Set(specs.map(\.id))
        let current = lock.withLock { fingerprints }

        for id in current.keys where !wanted.contains(id) {
            await registry.remove(id: id)
            lock.withLock { _ = fingerprints.removeValue(forKey: id) }
        }
        for spec in specs where current[spec.id] != spec.fingerprint {
            await registry.install(spec.make())
            lock.withLock { fingerprints[spec.id] = spec.fingerprint }
        }
    }

    /// Restarts one source (a "Reconnect" button).
    public func restart(sourceID: String) async {
        guard let source = await registry.source(id: sourceID) else { return }
        await source.stop()
        await source.start()
    }

    public func shutdown() async {
        await registry.stopAll()
        lock.withLock { fingerprints.removeAll() }
    }

    public func provider(for config: ProviderConfig) -> (any LLMProvider)? {
        providers.make(config, apiKey: secrets.read(config.secretAccount))
    }

    /// Everything one run needs, resolved now.
    public func makeLoop(
        settings: DropChatSettings,
        providerID: String?,
        model: String?,
        conversationID: UUID,
        approvals: any ApprovalHandler,
        isPreapproved: @escaping @Sendable (String) async -> Bool,
        rememberApproval: @escaping @Sendable (String) async -> Void
    ) async throws -> AgentLoop {
        let config = settings.providers.first { $0.id == providerID && $0.isEnabled } ?? settings.activeProvider
        guard let config, let provider = provider(for: config) else { throw ChatEngineError.noProvider }
        let modelName = (model?.isEmpty == false ? model : nil) ?? (config.defaultModel.isEmpty ? nil : config.defaultModel)
        guard let modelName else { throw ChatEngineError.noModel }

        let tools = await registry.availableTools()
        var contributors: [any PromptContributor] = []
        for id in await registry.sourceIDs {
            if let contributor = await registry.source(id: id) as? PromptContributor {
                contributors.append(contributor)
            }
        }
        let system = await SystemPromptBuilder(basePrompt: settings.general.systemPrompt, contributors: contributors).build()

        return AgentLoop(
            provider: provider,
            model: modelName,
            system: system,
            tools: tools,
            approvals: approvals,
            options: AgentOptions(maxSteps: max(1, settings.general.maxToolRounds)),
            context: ToolContext(conversationID: conversationID),
            isPreapproved: isPreapproved,
            rememberApproval: rememberApproval
        )
    }
}

public extension Conversation {
    /// A title from the first user message.
    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New chat" }
        return trimmed.count > 48 ? String(trimmed.prefix(47)) + "…" : trimmed
    }
}
