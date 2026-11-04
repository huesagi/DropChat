import AppKit
import CoreGraphics
import DroppyKit

/// Tells a tap of the shortcut from a hold. Droppy only reports the press, so
/// after it this polls the key state until the chord is released. Polling
/// runs only while the keys are down and reads no events (no Input Monitoring
/// permission needed).
@MainActor
final class ShortcutHoldTracker {
    /// Held at least this long, the shortcut counts as a peek.
    static let holdThreshold: Duration = .milliseconds(350)

    private var task: Task<Void, Never>?

    /// True while the chord that started tracking is still down.
    var isTracking: Bool { task != nil }

    /// Calls `onHoldReleased` when the chord is released after being held
    /// past the threshold. A tap calls nothing.
    func track(_ shortcut: DropletKeyboardShortcut, onHoldReleased: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled else { return }
                guard !Self.isHeld(shortcut) else { continue }
                self?.task = nil
                if clock.now - start >= Self.holdThreshold { onHoldReleased() }
                return
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// The key is down and the chord's modifiers are still held.
    static func isHeld(_ shortcut: DropletKeyboardShortcut) -> Bool {
        guard CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(shortcut.keyCode)) else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let required = NSEvent.ModifierFlags(rawValue: shortcut.modifiers).intersection(relevant)
        return NSEvent.modifierFlags.intersection(relevant).isSuperset(of: required)
    }
}
