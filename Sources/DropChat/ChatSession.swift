import AppKit
import Combine
import DropChatCore
import Foundation

/// One live chat, shared by every surface. Drives `AgentLoop` and turns its
/// events into published state.
@MainActor
final class ChatSession: ObservableObject {
    @Published private(set) var conversation = Conversation()
    @Published var input = ""
    @Published private(set) var attachments: [Attachment] = []
    @Published private(set) var isRunning = false
    @Published private(set) var draftText = ""
    @Published private(set) var draftReasoning = ""
    @Published private(set) var liveToolCalls: [ToolCall] = []
    @Published private(set) var runningToolIDs: Set<String> = []
    @Published private(set) var pendingApproval: ApprovalRequest?
    @Published var errorMessage: String?
    @Published private(set) var usage = TokenUsage()
    @Published var isAttaching = false

    /// Per-chat model choice; `nil` follows the settings' active provider.
    @Published var providerID: String?
    @Published var model: String?

    /// Weak: views can outlive `deactivate()`, which releases the model.
    private weak var app: AppModel?
    private var runTask: Task<Void, Never>?
    private var approvalQueue: [(ApprovalRequest, CheckedContinuation<ApprovalDecision, Never>)] = []
    private let approvalMemory = ToolApprovalMemory()

    init(app: AppModel) {
        self.app = app
    }

    var isBusy: Bool { isRunning || pendingApproval != nil }

    /// Results by call id, for the tool chips.
    var resultsByCallID: [String: ToolResult] {
        var results: [String: ToolResult] = [:]
        for message in conversation.messages {
            for result in message.toolResults { results[result.callID] = result }
        }
        return results
    }

    var visibleMessages: [ChatMessage] {
        conversation.messages.filter { !$0.isToolResultCarrier }
    }

    // MARK: - Model choice

    var activeProvider: ProviderConfig? {
        guard let settings = app?.settings else { return nil }
        return settings.providers.first { $0.id == (providerID ?? settings.activeProviderID) && $0.isEnabled } ?? settings.activeProvider
    }

    var activeModel: String {
        if let model, !model.isEmpty { return model }
        if providerID == nil, let model = app?.settings.activeModel, !model.isEmpty { return model }
        return activeProvider?.defaultModel ?? ""
    }

    func choose(provider: ProviderConfig, model: String) {
        providerID = provider.id
        self.model = model
        app?.update {
            $0.activeProviderID = provider.id
            $0.activeModel = model
        }
    }

    // MARK: - Sending

    var canSend: Bool {
        !isRunning && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send() {
        guard canSend else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = attachments.map(\.part)
        if !text.isEmpty { parts.append(.text(text)) }
        input = ""
        attachments = []
        if conversation.messages.isEmpty {
            conversation.title = Conversation.title(from: text.isEmpty ? (parts.first.flatMap(Self.attachmentName) ?? "Attachment") : text)
        }
        conversation.messages.append(ChatMessage(role: .user, parts: parts))
        run()
    }

    /// Runs the model again from the current transcript (after an error).
    func retry() {
        guard !isRunning, conversation.messages.last?.role == .user else { return }
        run()
    }

    private static func attachmentName(_ part: ContentPart) -> String? {
        switch part {
        case .document(let document): return document.filename
        case .image: return "Image"
        default: return nil
        }
    }

    private func run() {
        guard let app else { return }
        errorMessage = nil
        isRunning = true
        draftText = ""
        draftReasoning = ""
        liveToolCalls = []
        app.onBusyChanged?(true)

        let settings = app.settings
        let providerID = activeProvider?.id
        let model = activeModel
        let conversationID = conversation.id
        let bridge = ApprovalBridge(session: self)
        let engine = app.engine
        let approvalMemory = self.approvalMemory

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loop = try await engine.makeLoop(
                    settings: settings,
                    providerID: providerID,
                    model: model,
                    conversationID: conversationID,
                    approvals: bridge,
                    approvalMemory: approvalMemory
                )
                for try await event in loop.run(transcript: self.conversation.messages) {
                    self.handle(event)
                }
            } catch is CancellationError {
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.finishRun(cancelled: Task.isCancelled)
        }
    }

    func stop() {
        guard isRunning else { return }
        runTask?.cancel()
        let queue = approvalQueue
        approvalQueue = []
        pendingApproval = nil
        queue.forEach { $0.1.resume(returning: .deny) }
    }

    private func finishRun(cancelled: Bool) {
        if cancelled, !draftText.isEmpty {
            conversation.messages.append(ChatMessage(role: .assistant, parts: [.text(draftText)], model: activeModel, notice: "Stopped."))
        }
        conversation.messages = TranscriptRepair.closeDanglingToolCalls(conversation.messages)
        draftText = ""
        draftReasoning = ""
        liveToolCalls = []
        runningToolIDs = []
        isRunning = false
        runTask = nil
        conversation.updatedAt = Date()
        persist()
        app?.onBusyChanged?(isBusy)
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .stepStarted:
            draftText = ""
            draftReasoning = ""
        case .textDelta(let text):
            draftText += text
        case .reasoningDelta(let text):
            draftReasoning += text
        case .toolCallReceived(let call):
            liveToolCalls.append(call)
        case .toolStarted(let id):
            runningToolIDs.insert(id)
        case .toolFinished(let result):
            runningToolIDs.remove(result.callID)
        case .messageCompleted(let message):
            conversation.messages.append(message)
            if message.role == .assistant {
                draftText = ""
                draftReasoning = ""
                liveToolCalls = []
            }
        case .usage(let delta):
            usage = usage + delta
        case .finished:
            break
        }
    }

    // MARK: - Approvals

    fileprivate func enqueue(_ request: ApprovalRequest, _ continuation: CheckedContinuation<ApprovalDecision, Never>) {
        guard isRunning else {
            continuation.resume(returning: .deny)
            return
        }
        approvalQueue.append((request, continuation))
        if pendingApproval == nil {
            pendingApproval = request
            app?.onBusyChanged?(true)
            app?.onNeedsAttention?()
        }
    }

    func resolveApproval(_ decision: ApprovalDecision) {
        guard !approvalQueue.isEmpty else { return }
        let (_, continuation) = approvalQueue.removeFirst()
        pendingApproval = approvalQueue.first?.0
        continuation.resume(returning: decision)
    }

    // MARK: - Attachments

    func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            for url in urls.prefix(10) {
                do {
                    let attachment = try await AttachmentLoader.load(url)
                    if !attachments.contains(where: { $0.url == attachment.url }) {
                        attachments.append(attachment)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func attachFinderSelection() {
        Task {
            do {
                let urls = try await FinderSelection.selectedURLs()
                if urls.isEmpty {
                    errorMessage = "Nothing is selected in Finder."
                } else {
                    attach(urls)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Opens a file picker above the shelf.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        // The shelf floats above normal windows; keep the picker above it.
        panel.level = .popUpMenu
        isAttaching = true
        app?.onBusyChanged?(true)
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.isAttaching = false
                if response == .OK { self.attach(panel.urls) }
                self.app?.onBusyChanged?(self.isBusy)
            }
        }
    }

    // MARK: - Conversations

    func newChat() {
        stop()
        persist()
        conversation = Conversation()
        attachments = []
        errorMessage = nil
        usage = TokenUsage()
        approvalMemory.reset()
        if let general = app?.settings.general, general.autoAttachFinderSelection, general.finderSelectionEnabled {
            attachFinderSelection()
        }
    }

    func open(_ id: UUID) {
        guard id != conversation.id else { return }
        stop()
        persist()
        Task {
            guard let loaded = await app?.conversations.load(id) else { return }
            conversation = loaded
            providerID = loaded.providerID
            model = loaded.model
            approvalMemory.reset()
            usage = TokenUsage()
        }
    }

    private func persist() {
        guard let app, app.settings.general.saveHistory, !conversation.messages.isEmpty else { return }
        conversation.providerID = activeProvider?.id
        conversation.model = activeModel
        app.conversations.save(conversation)
        Task { await app.refreshHistory() }
    }

    func copyTranscript() {
        let text = visibleMessages.map { message in
            "\(message.role == .user ? "You" : "Assistant"):\n\(message.plainText)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Hands approval requests from the agent loop to the UI.
private final class ApprovalBridge: ApprovalHandler, @unchecked Sendable {
    weak var session: ChatSession?

    @MainActor init(session: ChatSession) {
        self.session = session
    }

    func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard let session = self.session else {
                    continuation.resume(returning: .deny)
                    return
                }
                session.enqueue(request, continuation)
            }
        }
    }
}
