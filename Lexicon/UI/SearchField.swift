//
//  SearchField.swift
//  Lexicon
//
//  An NSTextField wrapped for SwiftUI so we get:
//  - Auto-focus on appear
//  - Proper Esc handling (close panel)
//  - Up/Down arrows for history navigation (delegate hook)
//  - Spotlight-style large, light placeholder
//

import SwiftUI
import AppKit

struct SearchField: NSViewRepresentable {

    @Binding var text: String
    var placeholder: String = "Look up a word"
    /// Point size for the field + placeholder.
    var fontSize: CGFloat = 26
    /// When true, render the query in the New York serif (the Reading Room look).
    var serif: Bool = false
    /// Optional text color; defaults to the system label color.
    var textColor: NSColor? = nil
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onArrowUp: () -> Void = {}
    var onArrowDown: () -> Void = {}

    private func font(weight: NSFont.Weight) -> NSFont {
        if serif {
            let base = NSFont.systemFont(ofSize: fontSize, weight: weight)
            let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return NSFont(descriptor: descriptor, size: fontSize) ?? base
        }
        return NSFont.systemFont(ofSize: fontSize, weight: weight)
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = FocusableTextField()
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = font(weight: .regular)
        if let textColor { tf.textColor = textColor }
        tf.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: font(weight: .light),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.stringValue = text
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Re-grab focus on every show — the panel hands us focus by becoming key.
        DispatchQueue.main.async {
            if let window = nsView.window, window.firstResponder !== nsView.currentEditor() {
                window.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            let value = tf.stringValue
            // Defer to the next runloop tick so we don't publish state changes
            // synchronously from inside an AppKit notification dispatch — that
            // can trigger SwiftUI's "Modifying state during view update" warning.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.parent.text != value { self.parent.text = value }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(); return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrowUp(); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrowDown(); return true
            default:
                return false
            }
        }
    }
}

/// NSTextField subclass that becomes first responder as soon as it's added to a window.
private final class FocusableTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }
}
