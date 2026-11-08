import AppKit

/// The hosted field's editor, which says when composing text starts, changes or ends. Input methods do not
/// make a text field report those, and the payload needs them: while text is composing, every key goes to
/// the input method, Return and Escape included.
final class TextInputFieldEditor: NSTextView {
    var markedTextDidChange: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedTextDidChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        markedTextDidChange?()
    }

    /// The text without the part being composed.
    var committedString: String {
        let markedRange = markedRange()
        guard hasMarkedText(), markedRange.location != NSNotFound else { return string }
        return (string as NSString).replacingCharacters(in: markedRange, with: "")
    }
}
