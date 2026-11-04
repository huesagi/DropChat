import AppKit
import SwiftUI

/// The prompt field: an `NSTextView`, because SwiftUI's vertical `TextField`
/// cannot insert a line break at the cursor on Shift-Return and takes focus
/// unreliably inside Droppy's panels.
///
/// Return sends; Shift-Return and Option-Return insert a line break. The view
/// grows from one line to `maxLines`, then scrolls.
struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var textColor: NSColor
    var placeholderColor: NSColor
    /// Changing this moves the keyboard focus into the field.
    var focusToken: Int
    var font: NSFont = .systemFont(ofSize: 13)
    var maxLines: Int = 6
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = PromptNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        apply(to: textView)
        textView.string = text
        DispatchQueue.main.async { context.coordinator.recalculateHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        apply(to: textView)
        if textView.string != text {
            textView.string = text
            coordinator.recalculateHeight()
        }
        if coordinator.lastFocusToken != focusToken {
            coordinator.lastFocusToken = focusToken
            // After this layout pass, when the view is in its window.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
    }

    private func apply(to textView: PromptNSTextView) {
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.typingAttributes = [.font: font, .foregroundColor: textColor]
        textView.placeholderAttributes = [.font: font, .foregroundColor: placeholderColor]
        textView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextView
        weak var textView: PromptNSTextView?
        var lastFocusToken: Int

        init(_ parent: PromptTextView) {
            self.parent = parent
            // Not equal to the first token, so the field takes focus on appear.
            self.lastFocusToken = parent.focusToken - 1
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            recalculateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else if !textView.hasMarkedText() {
                parent.onSubmit()
            } else {
                return false
            }
            return true
        }

        func recalculateHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let lineHeight = layout.defaultLineHeight(for: parent.font)
            let used = layout.usedRect(for: container).height
            let height = min(max(used, lineHeight), lineHeight * CGFloat(parent.maxLines)).rounded(.up)
            textView.enclosingScrollView?.hasVerticalScroller = used > lineHeight * CGFloat(parent.maxLines)
            if abs(parent.height - height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = height }
            }
        }
    }
}

/// An `NSTextView` that draws a placeholder while empty.
final class PromptNSTextView: NSTextView {
    var placeholderString: String = "" { didSet { needsDisplay = true } }
    var placeholderAttributes: [NSAttributedString.Key: Any] = [:]

    override var string: String {
        didSet { needsDisplay = true }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholderString as NSString).draw(at: origin, withAttributes: placeholderAttributes)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
}
