import AppKit
import Combine
import DroppyKit
import DropChatCore
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. It only creates the droplet: it runs before the host
/// is ready.
@objc(DropChatPrincipal)
public final class DropChatPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { DropChatDroplet() }
}

/// DropChat: an LLM chat on the shelf, with an optional floating window.
@MainActor
public final class DropChatDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in Info.plist and `id` in droplet.json.
    public nonisolated static let id: DropletID = "dropchat"

    static let widgetID: ShelfWidgetID = "chat"
    static let floatingShortcutID = "toggle-floating-window"

    private var host: DropletHost?
    private(set) var app: AppModel?
    private var floatingPanel: FloatingPanelController?
    private var cancellables: Set<AnyCancellable> = []
    private var registeredShortcut = false

    public override init() { super.init() }

    public func activate(host: DropletHost) throws {
        self.host = host
        let app = AppModel(host: host)
        self.app = app

        app.onBusyChanged = { [weak self] busy in
            _ = self?.host?.shelf.setHoldsOpen(busy)
        }
        app.onNeedsAttention = { [weak self] in
            self?.surfaceChat()
        }
        // Re-broadcast model changes so Droppy re-reads our descriptors.
        app.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        app.$settings
            .map(\.general.floatingWindowEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in self?.floatingWindowSettingChanged(enabled) }
            .store(in: &cancellables)

        registerShortcut()
        app.start()
        host.log.info("DropChat activated")
    }

    public func deactivate() {
        cancellables.removeAll()
        floatingPanel?.tearDown()
        floatingPanel = nil
        if registeredShortcut {
            host?.shortcuts.unregister(id: Self.floatingShortcutID)
            registeredShortcut = false
        }
        _ = host?.shelf.setHoldsOpen(false)
        if let app {
            app.onBusyChanged = nil
            app.onNeedsAttention = nil
            // Stops runs and MCP server processes. Droppy may unload us right
            // after, so do not depend on this finishing; processes are also
            // sent SIGTERM synchronously by their transports.
            Task { await app.shutdown() }
        }
        app = nil
        host = nil
    }

    // MARK: - Floating window

    /// Option-Shift-Space shows or hides the chat: the floating window when
    /// it is on, the shelf otherwise. The id is unchanged from 0.1.0 so a
    /// binding the user set on Droppy's Shortcuts page survives.
    private func registerShortcut() {
        guard let host, !registeredShortcut else { return }
        // The host drops the default if it collides with another binding.
        let modifiers = NSEvent.ModifierFlags([.option, .shift]).rawValue
        host.shortcuts.register(
            id: Self.floatingShortcutID,
            title: "Show or hide DropChat",
            defaultShortcut: DropletKeyboardShortcut(keyCode: 49, modifiers: modifiers),
            handler: { [weak self] in self?.toggleChat() }
        )
        registeredShortcut = true
    }

    private func floatingWindowSettingChanged(_ enabled: Bool) {
        guard !enabled else { return }
        floatingPanel?.tearDown()
        floatingPanel = nil
    }

    /// The shortcut's action.
    func toggleChat() {
        guard let host, let app else { return }
        if app.settings.general.floatingWindowEnabled {
            toggleFloatingWindow()
            return
        }
        if host.shelf.isExpanded && host.shelf.soloWidgetID == Self.widgetID {
            host.shelf.close()
        } else {
            // Opening the widget alone makes the shelf key for it
            // (`.keyboardFocusable`); the composer then takes the focus.
            _ = host.shelf.open(revealing: Self.widgetID)
            app.session.requestFocus()
        }
    }

    private func panelController() -> FloatingPanelController? {
        guard let app, app.settings.general.floatingWindowEnabled else { return nil }
        if let floatingPanel { return floatingPanel }
        let controller = FloatingPanelController(app: app)
        controller.onBackToNotch = { [weak self] in
            _ = self?.host?.shelf.open(revealing: Self.widgetID)
        }
        floatingPanel = controller
        return controller
    }

    func toggleFloatingWindow() {
        panelController()?.toggle()
    }

    func popOutToFloatingWindow() {
        guard let controller = panelController() else { return }
        host?.shelf.close()
        controller.show()
    }

    /// Brings the chat in front of the user (an approval is waiting).
    private func surfaceChat() {
        if let floatingPanel, floatingPanel.isVisible {
            floatingPanel.show()
        } else {
            _ = host?.shelf.open(revealing: Self.widgetID)
        }
    }

    var canPopOut: Bool { app?.settings.general.floatingWindowEnabled ?? false }
}

// MARK: - Shelf widget

extension DropChatDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: Self.widgetID,
                title: "DropChat",
                systemImage: "bubble.left.and.text.bubble.right",
                layoutTraits: ShelfWidgetLayoutTraits(
                    // A chat needs room: a wide, tall card alone, and a
                    // one-line summary with an open button in a row.
                    preferredSoloWidth: 560,
                    preferredPairedWidth: 260,
                    contentHeight: .fixed(400)
                ),
                focusPolicy: .keyboardFocusable,
                // Never mount the chat invisibly ahead of time.
                prewarmPolicy: .never,
                searchKeywords: ["ai", "chat", "assistant", "llm", "gpt", "claude", "gemini"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        guard let app else { return AnyView(EmptyView()) }
        return AnyView(ShelfChatWidget(droplet: self, app: app, session: app.session, context: context))
    }
}

struct ShelfChatWidget: View {
    let droplet: DropChatDroplet
    @ObservedObject var app: AppModel
    @ObservedObject var session: ChatSession
    let context: ShelfWidgetContext

    private var popOut: (() -> Void)? {
        guard droplet.canPopOut else { return nil }
        let droplet = self.droplet
        return { droplet.popOutToFloatingWindow() }
    }

    var body: some View {
        Group {
            if context.isPaired {
                PairedChatSummary(droplet: droplet, app: app, session: session)
            } else {
                ChatView(
                    app: app,
                    session: session,
                    surface: .shelf,
                    onComposerAppear: {
                        guard !context.isPreview else { return }
                        _ = app.host.shelf.requestKeyboardFocus()
                    },
                    onPopOut: popOut
                )
            }
        }
        .environment(\.chatTheme, .shelf)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(context.contentInsets)
    }
}

/// The widget in a row with others: the latest reply and a way to open it.
struct PairedChatSummary: View {
    let droplet: DropChatDroplet
    @ObservedObject var app: AppModel
    @ObservedObject var session: ChatSession
    @Environment(\.chatTheme) private var theme

    private var lastReply: String {
        session.visibleMessages.last { $0.role == .assistant && !$0.plainText.isEmpty }?.plainText ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 12))
                Text("DropChat")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button {
                    _ = app.host.shelf.open(revealing: DropChatDroplet.widgetID)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
                .help("Open the chat")
            }
            .foregroundStyle(theme.primary)
            Text(session.isRunning ? "Answering…" : (lastReply.isEmpty ? "Open to start a chat." : lastReply))
                .font(.system(size: 12))
                .foregroundStyle(theme.secondary)
                .lineLimit(6)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Settings

extension DropChatDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        guard let app else { return AnyView(EmptyView()) }
        return AnyView(DropChatSettingsPane(app: app))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "Providers", keywords: ["api key", "openai", "anthropic", "google", "openrouter", "model"]),
            SettingsSearchEntry(title: "MCP servers", keywords: ["mcp", "tools"]),
            SettingsSearchEntry(title: "Web search", keywords: ["exa", "perplexity", "search", "crawl"]),
            SettingsSearchEntry(title: "Skills", keywords: ["agent skills", "skill.md"]),
            SettingsSearchEntry(title: "Floating window", keywords: ["window", "full screen", "overlay"]),
        ]
    }
}
