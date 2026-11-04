import AppKit
import DropChatCore
import DroppyKit
import SwiftUI

/// DropChat's settings page. Built from DroppyKit's rows so the host mounts
/// it in its native grouped form. It starts with the first setting: Droppy
/// already shows the droplet's name and icon above it.
struct DropChatSettingsPane: View {
    @ObservedObject var app: AppModel

    var body: some View {
        DropletSettingsPane {
            ChatSettingsSection(app: app)
            ProvidersSettingsSection(app: app)
            WindowAndFilesSection(app: app)
            WebSettingsSection(app: app)
            MCPSettingsSection(app: app)
            SkillsSettingsSection(app: app)
            PrivacySection(app: app)
        }
        .task { await app.watchStatuses() }
    }
}

// MARK: - Binding helpers

extension AppModel {
    func binding<Value>(_ keyPath: WritableKeyPath<DropChatSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    func providerBinding<Value>(_ id: String, _ keyPath: WritableKeyPath<ProviderConfig, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { self.settings.providers.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
            set: { value in
                self.update { settings in
                    guard let index = settings.providers.firstIndex(where: { $0.id == id }) else { return }
                    settings.providers[index][keyPath: keyPath] = value
                }
            }
        )
    }

    func serverBinding<Value>(_ id: String, _ keyPath: WritableKeyPath<MCPServerConfig, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { self.settings.mcpServers.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
            set: { value in
                self.update { settings in
                    guard let index = settings.mcpServers.firstIndex(where: { $0.id == id }) else { return }
                    settings.mcpServers[index][keyPath: keyPath] = value
                }
            }
        )
    }
}

/// A text field that commits when the user presses Return or leaves it, so
/// a half-typed URL never reaches the engine.
struct CommitTextField: View {
    let placeholder: String
    @Binding var value: String
    var monospaced = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, prompt: Text(placeholder))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .body)
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, newValue in if !focused { draft = newValue } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        if draft != value { value = draft }
    }
}

/// An API key field backed by the Keychain.
struct SecretField: View {
    @ObservedObject var app: AppModel
    let account: String
    var placeholder = "Paste a key"
    @State private var draft = ""
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            if app.hasSecret(account) && !isEditing {
                DropletValuePill(text: "Saved in Keychain")
                Spacer(minLength: 0)
                Button("Change") {
                    draft = ""
                    isEditing = true
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                Button("Remove") { app.setSecret("", for: account) }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
            } else {
                SecureField("", text: $draft, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if isEditing {
                    Button("Cancel") { isEditing = false }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
        }
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        app.setSecret(draft, for: account)
        draft = ""
        isEditing = false
    }
}

struct StatusText: View {
    let status: ToolSourceStatus?

    var body: some View {
        if let status {
            HStack(spacing: DroppySpacing.xs) {
                Circle()
                    .fill(color(status))
                    .frame(width: 6, height: 6)
                Text(status.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func color(_ status: ToolSourceStatus) -> Color {
        switch status {
        case .ready: return .green
        case .starting: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }
}

// MARK: - Chat

struct ChatSettingsSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        DropletSettingsSection {
            settingsSectionHeader("Chat")
        } content: {
            DropletSettingsCard {
                if app.settings.providers.isEmpty {
                    DropletControlRow(title: "Model", infoTip: "Add a provider below first.") {
                        DropletValuePill(text: "No provider")
                    }
                } else {
                    DropletGroupedPickerRow(title: "Provider") {
                        Picker("Provider", selection: app.binding(\.activeProviderID)) {
                            ForEach(app.settings.providers) { provider in
                                Text(provider.name).tag(Optional(provider.id))
                            }
                        }
                        .labelsHidden()
                    }
                    if let provider = app.settings.activeProvider {
                        DropletControlRow(title: "Model") {
                            ModelField(app: app, provider: provider, value: Binding(
                                get: { app.settings.activeModel ?? provider.defaultModel },
                                set: { value in app.update { $0.activeModel = value } }
                            ))
                        }
                    }
                }
                DropletStackedRow(title: "Instructions", infoTip: "Added to every chat as the system prompt. Leave empty for DropChat's default.") {
                    TextEditor(text: Binding(
                        get: { app.settings.general.systemPrompt },
                        set: { value in app.update { $0.general.systemPrompt = value } }
                    ))
                    .font(.system(size: 12))
                    .frame(minHeight: 60, maxHeight: 120)
                }
                DropletSliderRow(
                    title: "Tool rounds per answer",
                    value: "\(app.settings.general.maxToolRounds)",
                    binding: Binding<Double>(
                        get: { Double(app.settings.general.maxToolRounds) },
                        set: { value in app.update { $0.general.maxToolRounds = Int(value.rounded()) } }
                    ),
                    range: 1...50,
                    step: 1
                )
            }
        }
    }
}

/// A model name: a menu of known models plus free text.
struct ModelField: View {
    @ObservedObject var app: AppModel
    let provider: ProviderConfig
    @Binding var value: String
    @State private var message: String?
    @State private var isFetching = false

    var body: some View {
        VStack(alignment: .trailing, spacing: DroppySpacing.xs) {
            HStack(spacing: DroppySpacing.xs) {
                CommitTextField(placeholder: "Model id", value: $value, monospaced: true)
                    .frame(minWidth: 180, maxWidth: 260)
                Menu {
                    ForEach(app.models(for: provider), id: \.self) { model in
                        Button(model) { value = model }
                    }
                    Divider()
                    Button(isFetching ? "Fetching…" : "Fetch models from \(provider.name)") {
                        Task {
                            isFetching = true
                            message = await app.fetchModels(for: provider)
                            isFetching = false
                        }
                    }
                    .disabled(isFetching)
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Providers

struct ProvidersSettingsSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        ForEach(app.settings.providers) { provider in
            ProviderSection(app: app, provider: provider)
        }
        DropletSettingsCard {
            DropletControlRow(title: "Add a provider", icon: "plus.circle") {
                Menu("Add") {
                    ForEach(ProviderKind.allCases) { kind in
                        Button(kind.displayName) { app.addProvider(kind) }
                    }
                }
                .fixedSize()
            }
        }
    }
}

struct ProviderSection: View {
    @ObservedObject var app: AppModel
    let provider: ProviderConfig

    var body: some View {
        DropletSettingsSection {
            settingsSectionHeader(LocalizedStringKey(provider.name))
        } content: {
            DropletSettingsCard {
                DropletToggleRow(title: "Enabled", subtitle: provider.kind.displayName, isOn: app.providerBinding(provider.id, \.isEnabled, fallback: false))
                DropletStackedRow(title: "Name") {
                    CommitTextField(placeholder: provider.kind.displayName, value: app.providerBinding(provider.id, \.name, fallback: ""))
                }
                DropletStackedRow(title: provider.kind.requiresAPIKey ? "API key" : "API key (optional)") {
                    SecretField(app: app, account: provider.secretAccount)
                }
                DropletStackedRow(title: "Base URL", infoTip: provider.kind == .openAICompatible ? "Any server that speaks the OpenAI Chat Completions API, such as Ollama, LM Studio or vLLM." : "Change only for a proxy or a regional endpoint.") {
                    CommitTextField(placeholder: provider.kind.defaultBaseURL, value: app.providerBinding(provider.id, \.baseURL, fallback: ""), monospaced: true)
                }
                DropletControlRow(title: "Default model") {
                    ModelField(app: app, provider: provider, value: app.providerBinding(provider.id, \.defaultModel, fallback: ""))
                }
                DropletToggleRow(title: "Reasoning", subtitle: "Ask the model to think before it answers, where the API supports it, and show a summary.", isOn: app.providerBinding(provider.id, \.reasoningEnabled, fallback: true))
                if provider.kind == .anthropic {
                    DropletToggleRow(title: "Fallback on refusal", subtitle: "When a model declines a request, let the API retry it on a fallback model it picks.", isOn: app.providerBinding(provider.id, \.refusalFallbackEnabled, fallback: true))
                }
                DropletControlRow(title: "Maximum answer length", infoTip: "In tokens. Empty uses the provider's default.") {
                    CommitTextField(placeholder: "Default", value: Binding(
                        get: { app.settings.providers.first { $0.id == provider.id }?.maxOutputTokens.map(String.init) ?? "" },
                        set: { text in
                            app.update { settings in
                                guard let index = settings.providers.firstIndex(where: { $0.id == provider.id }) else { return }
                                settings.providers[index].maxOutputTokens = Int(text.trimmingCharacters(in: .whitespaces))
                            }
                        }
                    ))
                    .frame(width: 100)
                }
                if provider.kind == .openAICompatible || provider.kind == .openRouter {
                    DropletStackedRow(title: "Extra headers", infoTip: "One per line, as Name: value.") {
                        HeaderEditor(value: app.providerBinding(provider.id, \.extraHeaders, fallback: [:]))
                    }
                }
                DropletControlRow(title: "Remove this provider") {
                    Button("Remove") { app.removeProvider(provider.id) }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                }
            }
        }
    }
}

/// `Name: value` lines.
struct HeaderEditor: View {
    @Binding var value: [String: String]

    var body: some View {
        CommitTextField(
            placeholder: "X-Header: value",
            value: Binding(
                get: { value.keys.sorted().map { "\($0): \(value[$0] ?? "")" }.joined(separator: "; ") },
                set: { text in
                    var headers: [String: String] = [:]
                    for line in text.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
                        guard let colon = line.firstIndex(of: ":") else { continue }
                        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                        let content = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { headers[name] = content }
                    }
                    value = headers
                }
            ),
            monospaced: true
        )
    }
}

// MARK: - Window and files

struct WindowAndFilesSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        DropletSettingsSection {
            settingsSectionHeader("Window and chat")
        } content: {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Floating window",
                    subtitle: "A chat window that floats above other apps, full-screen ones included. When it is on, the shortcut shows or hides this window instead of opening the chat in the notch.",
                    isOn: app.binding(\.general.floatingWindowEnabled)
                )
                DropletControlRow(title: "Shortcut", infoTip: "Shows or hides DropChat from any app: the floating window when it is on, the chat in the notch otherwise. Option-Shift-Space unless you change it.") {
                    Button("Open Shortcuts") { _ = app.host.workspace.openShortcuts() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                DropletToggleRow(
                    title: "Start a new chat after closing",
                    subtitle: "When you reopen DropChat after it has been closed for a while, it starts a fresh chat. Earlier chats stay in your history.",
                    isOn: app.binding(\.general.autoNewChatEnabled)
                )
                if app.settings.general.autoNewChatEnabled {
                    DropletControlRow(title: "Closed for at least") {
                        HStack(spacing: DroppySpacing.sm) {
                            CommitTextField(
                                placeholder: "",
                                value: Binding(
                                    get: { String(app.settings.general.autoNewChatAfter) },
                                    set: { text in
                                        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
                                        app.update { $0.general.autoNewChatAfter = min(max(value, 1), 999) }
                                    }
                                )
                            )
                            .frame(width: 60)
                            Picker("Unit", selection: app.binding(\.general.autoNewChatUnit)) {
                                ForEach(TimeUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                DropletToggleRow(
                    title: "Finder selection",
                    subtitle: "Adds a button that attaches the files selected in Finder. macOS asks once to let Droppy control Finder.",
                    isOn: app.binding(\.general.finderSelectionEnabled)
                )
                if app.settings.general.finderSelectionEnabled {
                    DropletToggleRow(
                        title: "Attach on new chat",
                        subtitle: "Starting a new chat attaches Finder's selection automatically.",
                        isOn: app.binding(\.general.autoAttachFinderSelection)
                    )
                    DropletControlRow(title: "Automation permission") {
                        Button("Test") { app.session.attachFinderSelection() }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                }
            }
        }
    }
}

// MARK: - Web

struct WebSettingsSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        DropletSettingsSection {
            settingsSectionHeader("Web search")
        } content: {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Web tools",
                    subtitle: "Lets the model search the web and read pages. Queries go to the service you choose.",
                    isOn: app.binding(\.web.isEnabled)
                )
                if app.settings.web.isEnabled {
                    DropletGroupedPickerRow(title: "Search with") {
                        Picker("Search with", selection: app.binding(\.web.searchBackend)) {
                            ForEach(WebBackend.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                    }
                    DropletStackedRow(title: "Exa API key") {
                        SecretField(app: app, account: WebBackend.exa.secretAccount)
                    }
                    DropletStackedRow(title: "Perplexity API key") {
                        SecretField(app: app, account: WebBackend.perplexity.secretAccount)
                    }
                    if app.settings.web.searchBackend == .perplexity {
                        DropletGroupedPickerRow(title: "Perplexity returns") {
                            Picker("Perplexity returns", selection: app.binding(\.web.perplexityMode)) {
                                ForEach(PerplexityMode.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                    DropletToggleRow(
                        title: "Read pages with Exa",
                        subtitle: "With an Exa key, pages are read through Exa's crawler. Otherwise DropChat fetches them directly.",
                        isOn: app.binding(\.web.useExaForFetching)
                    )
                    DropletControlRow(title: "Status") {
                        StatusText(status: app.status(forSource: "web"))
                    }
                }
            }
        }
    }
}

// MARK: - MCP

struct MCPSettingsSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        ForEach(app.settings.mcpServers) { server in
            MCPServerSection(app: app, server: server)
        }
        DropletSettingsSection {
            settingsSectionHeader("Add an MCP server")
        } content: {
            DropletSettingsCard {
                AddMCPServerForm(app: app)
            }
        }
    }
}

struct MCPServerSection: View {
    @ObservedObject var app: AppModel
    let server: MCPServerConfig

    private var sourceID: String { "mcp.\(server.id)" }

    var body: some View {
        DropletSettingsSection {
            settingsSectionHeader(LocalizedStringKey("MCP: \(server.name)"))
        } content: {
            DropletSettingsCard {
                DropletToggleRow(title: "Enabled", subtitle: transportSummary, isOn: app.serverBinding(server.id, \.isEnabled, fallback: false))
                DropletControlRow(title: "Status") {
                    HStack(spacing: DroppySpacing.sm) {
                        StatusText(status: server.isEnabled ? (app.status(forSource: sourceID) ?? .starting) : .idle)
                        if server.isEnabled {
                            Button("Reconnect") { app.reconnect(sourceID: sourceID) }
                                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        }
                    }
                }
                DropletGroupedPickerRow(title: "Tool calls") {
                    Picker("Tool calls", selection: app.serverBinding(server.id, \.approvalMode, fallback: .ask)) {
                        ForEach(MCPApprovalMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                switch server.transport {
                case .stdio:
                    DropletStackedRow(title: "Environment", infoTip: "One per line, as NAME=value. Stored in the Keychain.") {
                        KeyValueEditor(separator: "=", value: app.serverBinding(server.id, \.environment, fallback: [:]))
                    }
                case .http:
                    DropletStackedRow(title: "Headers", infoTip: "One per line, as Name: value, for example Authorization: Bearer <token>. Stored in the Keychain.") {
                        KeyValueEditor(separator: ":", value: app.serverBinding(server.id, \.headers, fallback: [:]))
                    }
                }
                DropletControlRow(title: "Remove this server") {
                    Button("Remove") { app.removeServer(server.id) }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                }
            }
        }
    }

    private var transportSummary: String {
        switch server.transport {
        case .stdio(let command, let arguments, _): return ([command] + arguments).joined(separator: " ")
        case .http(let url): return url
        }
    }
}

/// Multi-line `key<sep>value` editing.
struct KeyValueEditor: View {
    let separator: Character
    @Binding var value: [String: String]
    @State private var draft = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .trailing, spacing: DroppySpacing.xs) {
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 44, maxHeight: 100)
            Button("Apply") { value = Self.parse(draft, separator: separator) }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                .disabled(Self.parse(draft, separator: separator) == value)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = value.keys.sorted().map { "\($0)\(separator == ":" ? ": " : "=")\(value[$0] ?? "")" }.joined(separator: "\n")
        }
    }

    static func parse(_ text: String, separator: Character) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let index = line.firstIndex(of: separator) else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            let content = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = content }
        }
        return result
    }
}

struct AddMCPServerForm: View {
    @ObservedObject var app: AppModel

    enum Mode: String, CaseIterable, Identifiable {
        case command = "Local command"
        case remote = "Remote URL"
        case importJSON = "Import JSON"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .command
    @State private var name = ""
    @State private var commandLine = ""
    @State private var url = ""
    @State private var token = ""
    @State private var json = ""
    @State private var message: String?

    var body: some View {
        DropletGroupedPickerRow(title: "Type") {
            Picker("Type", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
        }
        switch mode {
        case .command:
            DropletStackedRow(title: "Name") {
                TextField("", text: $name, prompt: Text("filesystem")).labelsHidden().textFieldStyle(.roundedBorder)
            }
            DropletStackedRow(title: "Command", infoTip: "The command and its arguments, as you would type them in Terminal.") {
                TextField("", text: $commandLine, prompt: Text("npx -y @modelcontextprotocol/server-filesystem ~/Documents"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
        case .remote:
            DropletStackedRow(title: "Name") {
                TextField("", text: $name, prompt: Text("my-server")).labelsHidden().textFieldStyle(.roundedBorder)
            }
            DropletStackedRow(title: "URL") {
                TextField("", text: $url, prompt: Text("https://example.com/mcp"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            DropletStackedRow(title: "Bearer token (optional)") {
                SecureField("", text: $token, prompt: Text("Token")).labelsHidden().textFieldStyle(.roundedBorder)
            }
        case .importJSON:
            DropletStackedRow(title: "Configuration", infoTip: "Paste an mcpServers object, the format MCP servers document for desktop apps.") {
                TextEditor(text: $json)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 160)
            }
        }
        DropletControlRow(title: message ?? " ") {
            Button("Add", action: add)
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
                .disabled(!canAdd)
        }
    }

    private var canAdd: Bool {
        switch mode {
        case .command: return !commandLine.trimmingCharacters(in: .whitespaces).isEmpty
        case .remote: return URL(string: url)?.scheme?.hasPrefix("http") == true
        case .importJSON: return !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func add() {
        var servers: [MCPServerConfig] = []
        switch mode {
        case .command:
            let words = ShellWords.split(commandLine)
            guard let command = words.first else { return }
            let fallbackName = URL(fileURLWithPath: words.last ?? command).lastPathComponent
            servers = [MCPServerConfig(name: name.isEmpty ? fallbackName : name, transport: .stdio(command: command, arguments: Array(words.dropFirst()), workingDirectory: nil))]
        case .remote:
            var headers: [String: String] = [:]
            if !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
            servers = [MCPServerConfig(name: name.isEmpty ? (URL(string: url)?.host ?? "server") : name, transport: .http(url: url), headers: headers)]
        case .importJSON:
            do {
                servers = try MCPServerConfig.importing(json: json)
                if servers.isEmpty {
                    message = "No servers found in that JSON."
                    return
                }
            } catch {
                message = "That is not valid JSON."
                return
            }
        }
        app.update { $0.mcpServers += servers }
        message = servers.count == 1 ? "Added \(servers[0].name)." : "Added \(servers.count) servers."
        name = ""
        commandLine = ""
        url = ""
        token = ""
        json = ""
    }
}

/// Splits a command line like a shell would (quotes and backslashes).
enum ShellWords {
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasWord = false
        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                hasWord = true
            } else if character == "\\" && quote != "'" {
                escaping = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasWord = true
            } else if character.isWhitespace {
                if hasWord {
                    words.append(current)
                    current = ""
                    hasWord = false
                }
            } else {
                current.append(character)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words.map { $0.hasPrefix("~/") ? ($0 as NSString).expandingTildeInPath : $0 }
    }
}

// MARK: - Skills

struct SkillsSettingsSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        DropletSettingsSection {
            settingsSectionHeader("Skills")
        } content: {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Agent skills",
                    subtitle: "Folders with a SKILL.md. The model sees each skill's name and description and loads the instructions when it needs them.",
                    isOn: app.binding(\.skills.isEnabled)
                )
                if app.settings.skills.isEnabled {
                    DropletStackedRow(title: "Skill folders", infoTip: "One folder per line. Each holds skill folders, or is one.") {
                        CommitTextField(
                            placeholder: "~/.claude/skills",
                            value: Binding(
                                get: { app.settings.skills.directories.joined(separator: "; ") },
                                set: { text in
                                    app.update { $0.skills.directories = text.split(whereSeparator: { $0 == ";" || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                                }
                            ),
                            monospaced: true
                        )
                    }
                    DropletControlRow(title: "Add a folder") {
                        Button("Choose…", action: chooseFolder)
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                    DropletToggleRow(
                        title: "Run skill scripts",
                        subtitle: "Lets skills run the scripts they bundle on your Mac. DropChat asks before every run.",
                        isOn: app.binding(\.skills.allowsScripts)
                    )
                    DropletControlRow(title: "Found") {
                        HStack(spacing: DroppySpacing.sm) {
                            StatusText(status: app.status(forSource: "skills"))
                            Button("Reload") { app.reconnect(sourceID: "skills") }
                                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        }
                    }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let path = (url.path as NSString).abbreviatingWithTildeInPath
                app.update { if !$0.skills.directories.contains(path) { $0.skills.directories.append(path) } }
            }
        }
    }
}

// MARK: - Privacy

struct PrivacySection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        DropletSettingsSection {
            settingsSectionHeader("History")
        } content: {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Save chats",
                    subtitle: "Keeps chats on this Mac, in DropChat's own folder, so you can reopen them.",
                    isOn: app.binding(\.general.saveHistory)
                )
                DropletControlRow(title: "Saved chats") {
                    HStack(spacing: DroppySpacing.sm) {
                        DropletValuePill(text: "\(app.recentConversations.count)")
                        Button("Delete all") { app.clearHistory() }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                            .disabled(app.recentConversations.isEmpty)
                    }
                }
            }
        }
    }
}
