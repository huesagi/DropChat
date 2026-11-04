import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - Secrets

/// Where API keys and tokens live. Never preferences: those are a plain-text
/// plist anything can read.
public protocol SecretStore: Sendable {
    func read(_ account: String) -> String?
    @discardableResult func write(_ value: String, for account: String) -> Bool
    func delete(_ account: String)
}

#if canImport(Security)
public struct KeychainSecretStore: SecretStore {
    /// Named after the droplet id so it never meets another droplet's items.
    public let service: String

    public init(service: String = "droplet.dropchat") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    public func write(_ value: String, for account: String) -> Bool {
        let base = baseQuery(account)
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
#endif

/// For tests and the harness.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = SyncLock()
    private var values: [String: String] = [:]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func read(_ account: String) -> String? { lock.withLock { values[account] } }

    @discardableResult
    public func write(_ value: String, for account: String) -> Bool {
        lock.withLock { values[account] = value.isEmpty ? nil : value }
        return true
    }

    public func delete(_ account: String) { lock.withLock { values[account] = nil } }
}

// MARK: - Settings

public struct WebSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var searchBackend: WebBackend
    public var perplexityMode: PerplexityMode
    /// Read pages through Exa when an Exa key is set, else fetch directly.
    public var useExaForFetching: Bool

    public init(isEnabled: Bool = false, searchBackend: WebBackend = .exa, perplexityMode: PerplexityMode = .search, useExaForFetching: Bool = true) {
        self.isEnabled = isEnabled
        self.searchBackend = searchBackend
        self.perplexityMode = perplexityMode
        self.useExaForFetching = useExaForFetching
    }
}

public struct SkillSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var directories: [String]
    public var allowsScripts: Bool

    public init(isEnabled: Bool = false, directories: [String] = ["~/.claude/skills"], allowsScripts: Bool = false) {
        self.isEnabled = isEnabled
        self.directories = directories
        self.allowsScripts = allowsScripts
    }

    public var directoryURLs: [URL] {
        directories.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }
}

public struct GeneralSettings: Codable, Hashable, Sendable {
    /// The floating window and its shortcut. Off until the user turns it on.
    public var floatingWindowEnabled: Bool
    /// Shows the "add Finder selection" button. Needs Automation permission.
    public var finderSelectionEnabled: Bool
    /// Attach Finder's selection automatically when a chat opens.
    public var autoAttachFinderSelection: Bool
    public var systemPrompt: String
    public var saveHistory: Bool
    public var maxToolRounds: Int

    public init(
        floatingWindowEnabled: Bool = false,
        finderSelectionEnabled: Bool = false,
        autoAttachFinderSelection: Bool = false,
        systemPrompt: String = "",
        saveHistory: Bool = true,
        maxToolRounds: Int = 25
    ) {
        self.floatingWindowEnabled = floatingWindowEnabled
        self.finderSelectionEnabled = finderSelectionEnabled
        self.autoAttachFinderSelection = autoAttachFinderSelection
        self.systemPrompt = systemPrompt
        self.saveHistory = saveHistory
        self.maxToolRounds = maxToolRounds
    }
}

/// Everything the user configures, minus secrets.
public struct DropChatSettings: Codable, Hashable, Sendable {
    public var providers: [ProviderConfig]
    public var activeProviderID: String?
    public var activeModel: String?
    public var mcpServers: [MCPServerConfig]
    public var web: WebSettings
    public var skills: SkillSettings
    public var general: GeneralSettings

    public init(
        providers: [ProviderConfig] = [],
        activeProviderID: String? = nil,
        activeModel: String? = nil,
        mcpServers: [MCPServerConfig] = [],
        web: WebSettings = WebSettings(),
        skills: SkillSettings = SkillSettings(),
        general: GeneralSettings = GeneralSettings()
    ) {
        self.providers = providers
        self.activeProviderID = activeProviderID
        self.activeModel = activeModel
        self.mcpServers = mcpServers
        self.web = web
        self.skills = skills
        self.general = general
    }

    // Tolerant decoding: a field added in a later version must not make an
    // older saved blob unreadable (that would silently reset every setting).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = (try? container.decode([ProviderConfig].self, forKey: .providers)) ?? []
        activeProviderID = try? container.decode(String.self, forKey: .activeProviderID)
        activeModel = try? container.decode(String.self, forKey: .activeModel)
        mcpServers = (try? container.decode([MCPServerConfig].self, forKey: .mcpServers)) ?? []
        web = (try? container.decode(WebSettings.self, forKey: .web)) ?? WebSettings()
        skills = (try? container.decode(SkillSettings.self, forKey: .skills)) ?? SkillSettings()
        general = (try? container.decode(GeneralSettings.self, forKey: .general)) ?? GeneralSettings()
    }

    public var activeProvider: ProviderConfig? {
        providers.first { $0.id == activeProviderID && $0.isEnabled } ?? providers.first { $0.isEnabled }
    }
}

/// Persists `DropChatSettings`. The droplet backs it with Droppy's
/// preferences service; tests use memory.
public protocol SettingsBackend: AnyObject {
    func loadSettingsData() -> Data?
    func saveSettingsData(_ data: Data)
}

/// Loads and saves settings, moving MCP credentials to the secret store.
public struct SettingsRepository {
    let backend: SettingsBackend
    let secrets: SecretStore

    public init(backend: SettingsBackend, secrets: SecretStore) {
        self.backend = backend
        self.secrets = secrets
    }

    struct MCPSecrets: Codable {
        var environment: [String: String]
        var headers: [String: String]
    }

    public func load() -> DropChatSettings {
        guard let data = backend.loadSettingsData(),
              var settings = try? JSONDecoder().decode(DropChatSettings.self, from: data) else {
            return DropChatSettings()
        }
        for index in settings.mcpServers.indices {
            let account = settings.mcpServers[index].secretAccount
            if let blob = secrets.read(account), let stored = try? JSONDecoder().decode(MCPSecrets.self, from: Data(blob.utf8)) {
                settings.mcpServers[index].environment = stored.environment
                settings.mcpServers[index].headers = stored.headers
            }
        }
        return settings
    }

    public func save(_ settings: DropChatSettings) {
        var stripped = settings
        for index in stripped.mcpServers.indices {
            let server = stripped.mcpServers[index]
            if server.environment.isEmpty && server.headers.isEmpty {
                secrets.delete(server.secretAccount)
            } else if let data = try? JSONEncoder().encode(MCPSecrets(environment: server.environment, headers: server.headers)) {
                secrets.write(String(decoding: data, as: UTF8.self), for: server.secretAccount)
            }
            stripped.mcpServers[index].environment = [:]
            stripped.mcpServers[index].headers = [:]
        }
        if let data = try? JSONEncoder().encode(stripped) {
            backend.saveSettingsData(data)
        }
    }

    /// Removes a server's or provider's secrets when it is deleted.
    public func forget(account: String) {
        secrets.delete(account)
    }
}

// MARK: - Conversations

/// Conversation history as one JSON file per chat in the droplet's container.
/// All I/O runs on its own queue.
public final class ConversationStore: @unchecked Sendable {
    public struct Summary: Sendable, Identifiable, Hashable {
        public var id: UUID
        public var title: String
        public var updatedAt: Date
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "dropchat.conversations", qos: .utility)

    public init(directory: URL) {
        self.directory = directory.appendingPathComponent("Conversations", isDirectory: true)
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func save(_ conversation: Conversation) {
        let url = fileURL(conversation.id)
        let directory = self.directory
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? ConversationStore.encoder.encode(conversation) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    public func load(_ id: UUID) async -> Conversation? {
        let url = fileURL(id)
        return await withCheckedContinuation { continuation in
            queue.async {
                let conversation = (try? Data(contentsOf: url)).flatMap { try? ConversationStore.decoder.decode(Conversation.self, from: $0) }
                continuation.resume(returning: conversation)
            }
        }
    }

    public func list(limit: Int = 50) async -> [Summary] {
        let directory = self.directory
        return await withCheckedContinuation { continuation in
            queue.async {
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                let sorted = files
                    .filter { $0.pathExtension == "json" }
                    .sorted {
                        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        return a > b
                    }
                    .prefix(limit)
                let summaries = sorted.compactMap { url -> Summary? in
                    guard let data = try? Data(contentsOf: url),
                          let conversation = try? ConversationStore.decoder.decode(Conversation.self, from: data) else { return nil }
                    return Summary(id: conversation.id, title: conversation.title, updatedAt: conversation.updatedAt)
                }
                continuation.resume(returning: summaries)
            }
        }
    }

    public func delete(_ id: UUID) {
        let url = fileURL(id)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    public func deleteAll() {
        let directory = self.directory
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }
}
