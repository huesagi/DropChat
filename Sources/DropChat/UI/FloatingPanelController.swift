import AppKit
import Combine
import DroppyKit
import SwiftUI

/// A panel that takes the keyboard without activating Droppy, so typing in
/// it leaves the app underneath frontmost (the way Spotlight behaves).
final class ChatPanel: NSPanel {
    /// Called whenever the panel leaves the screen (hide, Escape, close).
    var onOrderOut: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func orderOut(_ sender: Any?) {
        let wasVisible = isVisible
        super.orderOut(sender)
        if wasVisible { onOrderOut?() }
    }
}

/// The optional floating chat window. It joins every Space and floats over
/// full-screen apps. Unless it is pinned, it closes when the user clicks
/// anywhere else.
@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private let app: AppModel
    private var panel: ChatPanel?
    private var clickMonitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    let state: FloatingWindowState
    var onBackToNotch: (() -> Void)?

    static let autosaveName = "DropChatFloatingPanel"
    static let cornerRadius: CGFloat = DroppyRadius.xl
    static let chatMinSize = NSSize(width: 340, height: 320)

    init(app: AppModel) {
        self.app = app
        self.state = FloatingWindowState(preferences: app.host.preferences)
        super.init()
        state.$isSidebarVisible
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] visible in self?.sidebarVisibilityChanged(visible) }
            .store(in: &cancellables)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible
        panel.orderFrontRegardless()
        panel.makeKey()
        startClickMonitors()
        if !wasVisible, app.settings.general.scrollToBottomOnOpen {
            app.session.requestScrollToBottom()
        }
        // The SwiftUI view stays mounted while the panel is ordered out, so
        // its onAppear does not fire again: report the visibility here.
        app.session.surfaceAppeared(.floatingPanel)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Releases the window (called from `deactivate()`).
    func tearDown() {
        stopClickMonitors()
        cancellables.removeAll()
        panel?.orderOut(nil)
        panel?.onOrderOut = nil
        panel?.contentView = nil
        panel?.delegate = nil
        panel = nil
    }

    // MARK: - Closing on outside clicks

    /// Watches clicks only while the window is on screen. A global monitor
    /// sees clicks in other apps (mouse events need no permission); a local
    /// one sees clicks in Droppy's own windows, such as the shelf.
    private func startClickMonitors() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside(windowNumber: nil) }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let windowNumber = event.windowNumber
            MainActor.assumeIsolated { self?.clickedOutside(windowNumber: windowNumber) }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func stopClickMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
    }

    /// `windowNumber` is the clicked window in Droppy, `nil` for another app.
    private func clickedOutside(windowNumber: Int?) {
        guard let panel, panel.isVisible, !state.isPinned, !app.session.isAttaching else { return }
        if let windowNumber {
            guard windowNumber != panel.windowNumber else { return }
            // Menus, popovers and the file picker opened from the chat sit at
            // menu level or above, or are attached to the window.
            if let window = NSApp.window(withWindowNumber: windowNumber),
               window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue || window.parent === panel || window.sheetParent === panel {
                return
            }
        }
        hide()
    }

    // MARK: - Sidebar

    private static func minSize(sidebarVisible: Bool) -> NSSize {
        var size = chatMinSize
        if sidebarVisible { size.width += FloatingWindowState.sidebarWidth }
        return size
    }

    /// The chat keeps its width: the window grows to the left for the list
    /// and gives that width back when it closes. Called as the value changes
    /// (`@Published` publishes before the property is set).
    private func sidebarVisibilityChanged(_ visible: Bool) {
        guard let panel else { return }
        let delta = FloatingWindowState.sidebarWidth * (visible ? 1 : -1)
        var frame = panel.frame
        frame.origin.x -= delta
        frame.size.width += delta
        panel.minSize = Self.minSize(sidebarVisible: visible)
        frame.size.width = max(frame.width, panel.minSize.width)
        if let visibleFrame = panel.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - frame.width))
        }
        panel.setFrame(frame, display: true, animate: false)
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
        // Dragging moves the window only from the header and the top edge,
        // so a drag over a reply selects its text.
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        // Above normal windows and full-screen apps, on every Space.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = Self.minSize(sidebarVisible: state.isSidebarVisible)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onOrderOut = { [weak self] in
            self?.stopClickMonitors()
            self?.app.session.surfaceDisappeared(.floatingPanel)
        }

        let root = FloatingChatRoot(
            app: app,
            session: app.session,
            state: state,
            onBackToNotch: { [weak self] in
                self?.hide()
                self?.onBackToNotch?()
            },
            onClose: { [weak self] in self?.hide() }
        )
        let hosting = PanelHostingView(rootView: root)
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
    @ObservedObject var state: FloatingWindowState
    let onBackToNotch: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if state.isSidebarVisible {
                ChatSidebar(app: app, session: session)
                    .padding(.leading, DroppySpacing.md)
                    .padding(.trailing, DroppySpacing.sm)
                    .padding(.top, DroppySpacing.lg)
                    .padding(.bottom, DroppySpacing.md)
                    .frame(width: FloatingWindowState.sidebarWidth)
                    .background(ChatTheme.panel.raisedFill.opacity(0.5))
            }
            ChatView(app: app, session: session, surface: .floatingPanel, onPopOut: onBackToNotch, onClose: onClose, windowState: state)
                .padding(.horizontal, DroppySpacing.lg)
                .padding(.top, DroppySpacing.lg)
                .padding(.bottom, DroppySpacing.md)
        }
        .environment(\.chatTheme, .panel)
        // The strip above the header moves the window too.
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: DroppySpacing.lg)
        }
        .background(DroppyPanelSurface(cornerRadius: FloatingPanelController.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: FloatingPanelController.cornerRadius, style: .continuous))
        .ignoresSafeArea()
    }
}
