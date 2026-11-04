import AppKit
import DroppyKit
import SwiftUI

/// What the floating window remembers about itself: whether it is pinned and
/// whether the chat list is open. Kept in Droppy's preferences for this
/// droplet, apart from the settings blob, so toggling them never re-applies
/// the engine.
@MainActor
final class FloatingWindowState: ObservableObject {
    static let sidebarWidth: CGFloat = 200
    private static let pinnedKey = "floatingWindow.pinned"
    private static let sidebarKey = "floatingWindow.sidebarVisible"

    /// A pinned window stays open when the user clicks elsewhere or releases
    /// a held shortcut.
    @Published var isPinned: Bool {
        didSet { preferences?.setValue(isPinned, forKey: Self.pinnedKey) }
    }

    @Published var isSidebarVisible: Bool {
        didSet { preferences?.setValue(isSidebarVisible, forKey: Self.sidebarKey) }
    }

    private weak var preferences: (any DropletPreferencesService)?

    init(preferences: any DropletPreferencesService) {
        self.preferences = preferences
        self.isPinned = preferences.value(forKey: Self.pinnedKey, default: false)
        self.isSidebarVisible = preferences.value(forKey: Self.sidebarKey, default: false)
    }
}

/// The floating window's content view. The window is not movable by its
/// background, so a drag that starts on text selects it; this keeps the
/// hosting view from claiming such drags for the window as well.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// An empty strip that moves its window when dragged: the header and the
/// window's top edge.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
