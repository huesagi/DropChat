import AppKit
import DropChatCore
import DroppyKit
import SwiftUI
import UniformTypeIdentifiers

/// The whole chat: header, transcript, approval, composer. Mounted by the
/// shelf widget and by the floating window.
struct ChatView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: ChatSession
    let surface: ChatSurface
    /// Called when the composer appears (the shelf asks for keyboard focus).
    var onComposerAppear: (() -> Void)?
    var onPopOut: (() -> Void)?
    var onClose: (() -> Void)?
    /// The floating window's pin and sidebar; `nil` on the shelf.
    var windowState: FloatingWindowState?

    @Environment(\.chatTheme) private var theme
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            ChatHeader(app: app, session: session, surface: surface, onPopOut: onPopOut, onClose: onClose, windowState: windowState)
            if app.settings.providers.isEmpty {
                SetupPrompt(app: app)
            } else {
                transcript
                if let request = session.pendingApproval {
                    ApprovalCard(request: request) { session.resolveApproval($0) }
                }
                if let error = session.errorMessage {
                    ErrorBanner(message: error, canRetry: session.conversation.messages.last?.role == .user && !session.isRunning, retry: session.retry, dismiss: { session.errorMessage = nil })
                }
                ComposerView(app: app, session: session, onAppear: onComposerAppear)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { session.surfaceAppeared(surface) }
        .onDisappear { session.surfaceDisappeared(surface) }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedFiles(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                    .fill(theme.raisedFill)
                    .overlay(Label("Drop to attach", systemImage: "paperclip").foregroundStyle(theme.primary))
                    .allowsHitTesting(false)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DroppySpacing.md) {
                    if session.visibleMessages.isEmpty && !session.isRunning {
                        EmptyChatHint(session: session)
                    }
                    let results = session.resultsByCallID
                    ForEach(session.visibleMessages) { message in
                        MessageRow(message: message, results: results, runningToolIDs: session.runningToolIDs)
                            .id(message.id)
                    }
                    if session.isRunning {
                        LiveTurnView(session: session)
                            .id("live")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.trailing, DroppySpacing.xs)
            }
            .scrollIndicators(.never)
            .onChange(of: session.draftText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.conversation.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.scrollToBottomToken) { _, _ in scrollToBottom(proxy) }
            .onChange(of: session.conversation.id) { _, _ in scrollToBottom(proxy) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// After the next layout pass: the window may have just come back on
    /// screen, or a different chat just replaced the rows.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        let session = self.session
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in session.attach([url]) }
            }
        }
    }
}

/// What the model is writing right now.
struct LiveTurnView: View {
    @ObservedObject var session: ChatSession
    @Environment(\.chatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            if !session.draftReasoning.isEmpty && session.draftText.isEmpty {
                ReasoningDisclosure(text: session.draftReasoning, isLive: true)
            }
            if !session.draftText.isEmpty {
                MarkdownText(text: session.draftText)
            }
            ForEach(session.liveToolCalls) { call in
                ToolCallChip(call: call, result: nil, isRunning: session.runningToolIDs.contains(call.id))
            }
            if session.draftText.isEmpty && session.liveToolCalls.isEmpty && session.pendingApproval == nil {
                HStack(spacing: DroppySpacing.xsm) {
                    ProgressView().controlSize(.small)
                    Text(session.runningToolIDs.isEmpty ? "Thinking…" : "Running tools…")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatHeader: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: ChatSession
    let surface: ChatSurface
    var onPopOut: (() -> Void)?
    var onClose: (() -> Void)?
    var windowState: FloatingWindowState?
    @Environment(\.chatTheme) private var theme

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            if let windowState {
                SidebarToggle(state: windowState)
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondary)
            }
            ModelMenu(app: app, session: session)
            Spacer(minLength: 0)
            if let windowState {
                // The chat list replaces the menu while it is open.
                HiddenWhileSidebarOpen(state: windowState) {
                    HistoryMenu(app: app, session: session)
                }
            } else {
                HistoryMenu(app: app, session: session)
            }
            Button(action: session.newChat) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .keyboardShortcut("n", modifiers: .command)
            .help("New chat (⌘N)")
            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: surface == .shelf ? "macwindow.on.rectangle" : "rectangle.inset.topright.filled")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
                .help(surface == .shelf ? "Open in a floating window" : "Back to the notch")
            }
            if let windowState {
                PinToggle(state: windowState)
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
                .help("Close")
            }
        }
        // In the floating window, the header's empty space moves the window.
        .background {
            if windowState != nil { WindowDragArea() }
        }
    }
}

struct HiddenWhileSidebarOpen<Content: View>: View {
    @ObservedObject var state: FloatingWindowState
    @ViewBuilder let content: () -> Content

    var body: some View {
        if !state.isSidebarVisible { content() }
    }
}

/// Shows or hides the floating window's chat list.
struct SidebarToggle: View {
    @ObservedObject var state: FloatingWindowState

    var body: some View {
        Button {
            state.isSidebarVisible.toggle()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help(state.isSidebarVisible ? "Hide chats (⌃⌘S)" : "Show chats (⌃⌘S)")
    }
}

/// Keeps the floating window open when the user clicks elsewhere.
struct PinToggle: View {
    @ObservedObject var state: FloatingWindowState

    var body: some View {
        Button {
            state.isPinned.toggle()
        } label: {
            Image(systemName: state.isPinned ? "pin.fill" : "pin")
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .help(state.isPinned ? "Unpin: close when you click elsewhere" : "Pin: keep open when you click elsewhere")
    }
}

struct ModelMenu: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: ChatSession
    @Environment(\.chatTheme) private var theme

    var body: some View {
        Menu {
            ForEach(app.settings.providers.filter(\.isEnabled)) { provider in
                Section(provider.name) {
                    ForEach(app.models(for: provider), id: \.self) { model in
                        Button {
                            session.choose(provider: provider, model: model)
                        } label: {
                            if provider.id == session.activeProvider?.id && model == session.activeModel {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Settings…") { _ = app.host.workspace.openSettings() }
        } label: {
            HStack(spacing: DroppySpacing.xs) {
                Text(session.activeModel.isEmpty ? "Choose a model" : session.activeModel)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(theme.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct HistoryMenu: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: ChatSession

    var body: some View {
        Menu {
            if app.recentConversations.isEmpty {
                Text("No saved chats")
            }
            ForEach(app.recentConversations) { summary in
                Button(summary.title) { session.open(summary.id) }
            }
            if !session.visibleMessages.isEmpty {
                Divider()
                Button("Copy this chat") { session.copyTranscript() }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(DroppyCircleButtonStyle(size: 24))
        .help("Recent chats")
    }
}

struct ComposerView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: ChatSession
    var onAppear: (() -> Void)?
    @State private var inputHeight: CGFloat = 16
    @Environment(\.chatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            if !session.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DroppySpacing.xs) {
                        ForEach(session.attachments) { attachment in
                            AttachmentPill(name: attachment.name, systemImage: attachment.systemImage) {
                                session.removeAttachment(attachment.id)
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: DroppySpacing.sm) {
                Button(action: session.chooseFiles) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
                .help("Attach files")
                if app.settings.general.finderSelectionEnabled {
                    Button(action: session.attachFinderSelection) {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 24))
                    .help("Attach what is selected in Finder")
                }
                PromptTextView(
                    text: $session.input,
                    height: $inputHeight,
                    placeholder: "Message",
                    textColor: NSColor(theme.primary),
                    placeholderColor: NSColor(theme.tertiary),
                    focusToken: session.focusToken,
                    onSubmit: { session.send() }
                )
                    .frame(height: inputHeight)
                    .padding(.horizontal, DroppySpacing.smd)
                    .padding(.vertical, DroppySpacing.xsm)
                    .background(theme.raisedFill, in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
                if session.isRunning {
                    Button(action: session.stop) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 24))
                    .help("Stop")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button(action: session.send) {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 24))
                    .disabled(!session.canSend)
                    .help("Send")
                }
            }
        }
        .onAppear { onAppear?() }
    }
}

struct EmptyChatHint: View {
    @ObservedObject var session: ChatSession
    @Environment(\.chatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Text("Ask anything.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.primary)
            Text("Drop files here to attach them. Tools you connect in settings are available to the model.")
                .font(.system(size: 12))
                .foregroundStyle(theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DroppySpacing.sm)
    }
}

struct SetupPrompt: View {
    @ObservedObject var app: AppModel
    @Environment(\.chatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text("Connect a model to start chatting.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.primary)
            Text("Add an API key for OpenAI, Anthropic, Google, OpenRouter or your own endpoint in DropChat's settings.")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set up") { _ = app.host.workspace.openSettings() }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ErrorBanner: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void
    let dismiss: () -> Void
    @Environment(\.chatTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: DroppySpacing.sm) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if canRetry {
                Button("Retry", action: retry)
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
        }
        .foregroundStyle(theme.secondary)
        .padding(DroppySpacing.sm)
        .background(theme.raisedFill, in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
    }
}
