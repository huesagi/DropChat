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

extension FloatingWindowState {
    /// The drag areas' double-click action: toggles the pin, or nothing when
    /// the user turned double-click to pin off.
    func pinToggle(enabled: Bool) -> (() -> Void)? {
        enabled ? { [weak self] in self?.isPinned.toggle() } : nil
    }
}

/// An empty strip that moves its window when dragged: the header and the
/// window's top edge. Double-clicking it runs `onDoubleClick`.
///
/// It moves the window itself instead of reporting `mouseDownCanMoveWindow`
/// or calling `performDrag`: either makes macOS treat the strip as a title
/// bar, and a title bar's double-click zooms the window to fill the screen.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DragView)?.onDoubleClick = onDoubleClick
    }

    final class DragView: NSView {
        var onDoubleClick: (() -> Void)?
        /// Where the mouse and the window's origin were when the drag began.
        private var dragStart: (mouse: NSPoint, origin: NSPoint)?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                dragStart = nil
                onDoubleClick()
                return
            }
            guard let window else { return }
            dragStart = (NSEvent.mouseLocation, window.frame.origin)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let dragStart else { return }
            let mouse = NSEvent.mouseLocation
            var origin = NSPoint(
                x: dragStart.origin.x + mouse.x - dragStart.mouse.x,
                y: dragStart.origin.y + mouse.y - dragStart.mouse.y
            )
            // Keep the top edge below the menu bar and the notch, the way a
            // system drag does.
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? window.screen {
                origin.y = min(origin.y, screen.visibleFrame.maxY - window.frame.height)
            }
            window.setFrameOrigin(origin)
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
        }
    }
}
