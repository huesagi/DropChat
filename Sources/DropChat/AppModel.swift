import Combine
import DroppyKit
import DropChatCore
import Foundation

/// The composition root. Everything DropChat runs is created here, from
/// settings, and torn down in `shutdown()`.
///
/// To add a feature:
/// - a provider protocol: implement `LLMProvider`, register it in `ProviderFactory`;
/// - a tool family: write a `ToolSource` and a `ToolSourceBuilder`, append it to `toolSourceBuilders`;
/// - a chat surface: bind a view to `session`.
@MainActor
final class AppModel: ObservableObject {
    static let toolSourceBuilders: [ToolSourceBuilder] = BuiltInToolSources.all

    @Published private(set) var settings: DropChatSettings
    @Published private(set) var sourceStatuses: [(id: String, name: String, status: ToolSourceStatus)] = []
    @Published private(set) var fetchedModels: [String: [ModelInfo]] = [:]
    @Published private(set) var recentConversations: [ConversationStore.Summary] = []

    let host: DropletHost
    let secrets: SecretStore
    let engine: ChatEngine
    let conversations: ConversationStore
    private let repository: SettingsRepository
    private let backend: PreferencesSettingsBackend
    private var saveTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?

    /// The one conversation every surface shows: the shelf widget and the
    /// floating window are two views of the same chat.
    private(set) lazy var session = ChatSession(app: self)

    /// Called when the chat needs the user (an approval is waiting).
    var onNeedsAttention: (() -> Void)?
    /// Called when the shelf should stay open (a run or an approval is in progress).
    var onBusyChanged: ((Bool) -> Void)?

    init(host: DropletHost) {
        self.host = host
        self.secrets = KeychainSecretStore(service: "droplet.\(DropChatDroplet.id.rawValue)")
        self.engine = ChatEngine(secrets: secrets, builders: Self.toolSourceBuilders)
        self.backend = PreferencesSettingsBackend(preferences: host.preferences)
        self.repository = SettingsRepository(backend: backend, secrets: secrets)
        self.conversations = ConversationStore(directory: host.environment.containerDirectory)
        self.settings = repository.load()
    }

    func start() {
        scheduleApply()
        Task { await refreshHistory() }
    }

    func shutdown() async {
        applyTask?.cancel()
        saveTask?.cancel()
        repository.save(settings)
        session.stop()
        await engine.shutdown()
    }

    // MARK: - Settings

    func update(_ change: (inout DropChatSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        scheduleSave()
        scheduleApply()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.repository.save(self.settings)
        }
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            // Debounced: typing a URL must not restart a server per keystroke.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            await self.engine.apply(self.settings)
            await self.refreshStatuses()
        }
    }

    func refreshStatuses() async {
        let statuses = await engine.registry.statuses()
        if statuses.map({ "\($0.id)\($0.status)" }) != sourceStatuses.map({ "\($0.id)\($0.status)" }) {
            sourceStatuses = statuses
        }
    }

    /// Tool sources connect in the background. Their status is polled only
    /// while a view that shows it is on screen (run from its `.task`).
    func watchStatuses() async {
        while !Task.isCancelled {
            await refreshStatuses()
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    func status(forSource id: String) -> ToolSourceStatus? {
        sourceStatuses.first { $0.id == id }?.status
    }

    func reconnect(sourceID: String) {
        Task {
            await engine.restart(sourceID: sourceID)
            await refreshStatuses()
        }
    }

    // MARK: - Secrets

    func secret(_ account: String) -> String { secrets.read(account) ?? "" }

    func setSecret(_ value: String, for account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { secrets.delete(account) } else { secrets.write(trimmed, for: account) }
        objectWillChange.send()
        scheduleApply()
    }

    func hasSecret(_ account: String) -> Bool { !(secrets.read(account) ?? "").isEmpty }

    // MARK: - Providers

    func addProvider(_ kind: ProviderKind) {
        let config = ProviderConfig(kind: kind)
        update {
            $0.providers.append(config)
            if $0.activeProviderID == nil { $0.activeProviderID = config.id }
        }
    }

    func removeProvider(_ id: String) {
        if let config = settings.providers.first(where: { $0.id == id }) {
            repository.forget(account: config.secretAccount)
        }
        update {
            $0.providers.removeAll { $0.id == id }
            if $0.activeProviderID == id { $0.activeProviderID = $0.providers.first?.id }
        }
    }

    func fetchModels(for config: ProviderConfig) async -> String? {
        guard let provider = engine.provider(for: config) else { return "This provider is not available." }
        do {
            let models = try await provider.listModels()
            fetchedModels[config.id] = models
            return models.isEmpty ? "The provider listed no models." : nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The models to offer for a provider: pinned, default, live, suggested.
    func models(for config: ProviderConfig) -> [String] {
        var seen = Set<String>()
        let all = [config.defaultModel] + config.pinnedModels + (fetchedModels[config.id]?.map(\.id) ?? config.kind.suggestedModels)
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - MCP

    func removeServer(_ id: String) {
        if let server = settings.mcpServers.first(where: { $0.id == id }) {
            repository.forget(account: server.secretAccount)
        }
        update { $0.mcpServers.removeAll { $0.id == id } }
    }

    // MARK: - History

    func refreshHistory() async {
        recentConversations = await conversations.list(limit: 50)
    }

    func renameConversation(_ id: UUID, to title: String) {
        let title = Conversation.cleanTitle(title)
        guard !title.isEmpty else { return }
        if let index = recentConversations.firstIndex(where: { $0.id == id }) {
            recentConversations[index].title = title
        }
        if session.conversation.id == id { session.renameCurrent(title) }
        Task { await conversations.rename(id, to: title) }
    }

    /// Deletes a saved chat. Deleting the open chat starts a new one.
    func deleteConversation(_ id: UUID) {
        recentConversations.removeAll { $0.id == id }
        if session.conversation.id == id { session.discardCurrent() }
        conversations.delete(id)
    }

    func clearHistory() {
        conversations.deleteAll()
        recentConversations = []
    }
}

/// Settings live in Droppy's preferences for this droplet, as one JSON
/// string. Secrets were already moved to the Keychain by `SettingsRepository`.
final class PreferencesSettingsBackend: SettingsBackend {
    static let key = "settings.v1"
    let preferences: any DropletPreferencesService

    init(preferences: any DropletPreferencesService) {
        self.preferences = preferences
    }

    func loadSettingsData() -> Data? {
        MainActor.assumeIsolated {
            preferences.value(forKey: PreferencesSettingsBackend.key, as: String.self).map { Data($0.utf8) }
        }
    }

    func saveSettingsData(_ data: Data) {
        MainActor.assumeIsolated {
            preferences.setValue(String(decoding: data, as: UTF8.self), forKey: PreferencesSettingsBackend.key)
        }
    }
}
