import AppKit
import DroppyKit
import SwiftUI

/// A panel that takes the keyboard without activating Droppy, so typing in
/// it leaves the app underneath frontmost (the way Spotlight behaves).
final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// The optional floating chat window. It joins every Space and floats over
/// full-screen apps.
@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private let app: AppModel
    private var panel: ChatPanel?
    var onBackToNotch: (() -> Void)?

    static let autosaveName = "DropChatFloatingPanel"
    static let cornerRadius: CGFloat = DroppyRadius.xl

    init(app: AppModel) {
        self.app = app
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Releases the window (called from `deactivate()`).
    func tearDown() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.delegate = nil
        panel = nil
    }

    private func makePanel() -> ChatPanel {
        let panel = ChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        // Above normal windows and full-screen apps, on every Space.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 340, height: 320)
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let root = FloatingChatRoot(
            app: app,
            session: app.session,
            onBackToNotch: { [weak self] in
                self?.hide()
                self?.onBackToNotch?()
            },
            onClose: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting

        if !panel.setFrameUsingName(Self.autosaveName) {
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: visible.maxX - 460, y: visible.maxY - 600))
            } else {
                panel.center()
            }
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        return panel
    }

    func windowWillClose(_ notification: Notification) {}
}

private struct FloatingChatRoot: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: ChatSession
    let onBackToNotch: () -> Void
    let onClose: () -> Void

    var body: some View {
        ChatView(app: app, session: session, surface: .floatingPanel, onPopOut: onBackToNotch, onClose: onClose)
            .environment(\.chatTheme, .panel)
            .padding(.horizontal, DroppySpacing.lg)
            .padding(.top, DroppySpacing.lg)
            .padding(.bottom, DroppySpacing.md)
            .background(DroppyPanelSurface(cornerRadius: FloatingPanelController.cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: FloatingPanelController.cornerRadius, style: .continuous))
            .ignoresSafeArea()
    }
}
