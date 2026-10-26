import AppKit
import SwiftUI

/// Multi-line message field for the chat composer. Return sends, Shift/Option-Return adds a line.
/// When `highlightsFirstLine` is set, the first line — which becomes the email's subject — is
/// shown bold in the accent color on a soft highlight, so it's clear what the subject will be.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var highlightsFirstLine: Bool
    var focusOnAppear = true
    var onSubmit: () -> Void

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)
    static let subjectFont = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
    static let maxLines: CGFloat = 10

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isContinuousSpellCheckingEnabled = true
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.applyStyle()

        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        DispatchQueue.main.async { context.coordinator.updateHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let highlightChanged = coordinator.parent.highlightsFirstLine != highlightsFirstLine
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            coordinator.applyStyle()
            DispatchQueue.main.async { coordinator.updateHeight() }
        } else if highlightChanged {
            coordinator.applyStyle()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyStyle()
            updateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        func applyStyle() {
            // Restyling while an input method is composing would break the marked text.
            guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: ComposerTextView.font, .foregroundColor: NSColor.labelColor], range: full)
            if parent.highlightsFirstLine, storage.length > 0 {
                let string = storage.string as NSString
                let newline = string.range(of: "\n").location
                let firstLine = NSRange(location: 0, length: newline == NSNotFound ? string.length : newline)
                if firstLine.length > 0 {
                    storage.addAttributes([
                        .font: ComposerTextView.subjectFont,
                        .foregroundColor: NSColor.controlAccentColor,
                        .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.14),
                    ], range: firstLine)
                }
            }
            storage.endEditing()
            let inFirstLine = parent.highlightsFirstLine
                && !(storage.string as NSString).substring(to: min(textView.selectedRange().location, storage.length)).contains("\n")
            textView.typingAttributes = inFirstLine
                ? [.font: ComposerTextView.subjectFont, .foregroundColor: NSColor.controlAccentColor]
                : [.font: ComposerTextView.font, .foregroundColor: NSColor.labelColor]
        }

        func updateHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let lineHeight = layout.defaultLineHeight(for: ComposerTextView.font)
            let used = layout.usedRect(for: container).height
            let inset = textView.textContainerInset.height * 2
            let height = min(max(used, lineHeight), lineHeight * ComposerTextView.maxLines) + inset
            if abs(parent.height - height) > 0.5 {
                parent.height = height
            }
        }
    }
}
