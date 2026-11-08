import Foundation

/// The general pasteboard, as the fields need it: plain text in and out.
protocol SpringboardPasteboard {
    func string() -> String?
    func setString(_ string: String)
}

/// A field's text with its undo history and the Edit menu's commands, what the field editor of the
/// `NSTextField`s macOS 15 hosted for the search and rename fields gave them.
///
/// Undo goes back a step at a time: a run of typing is one step, ended by moving the caret, deleting,
/// cutting or pasting, as in a text field.
struct SpringboardFieldEditor {
    private(set) var editing: SpringboardTextEditing
    private var undoSnapshots: [SpringboardTextEditing] = []
    private var redoSnapshots: [SpringboardTextEditing] = []
    private var isTyping = false

    init(editing: SpringboardTextEditing) {
        self.editing = editing
    }

    var text: String {
        editing.text
    }

    /// Changes the selection or the caret, as a click or a drag in the field does; it ends a run of typing.
    mutating func select(_ body: (inout SpringboardTextEditing) -> Void) {
        isTyping = false
        body(&editing)
    }

    /// Applies `command`. `.endEditing` is the owner's to handle and changes nothing here.
    mutating func apply(_ command: SpringboardTextEditingCommand, pasteboard: some SpringboardPasteboard) {
        switch command {
        case let .insert(typedText):
            change(isTyping: true) { $0.insert(typedText) }
        case let .move(movement, extendingSelection):
            isTyping = false
            editing.move(movement, extendingSelection: extendingSelection)
        case let .delete(deletion):
            change { $0.delete(deletion) }
        case .selectAll:
            isTyping = false
            editing.selectAll()
        case .copy:
            guard editing.hasSelection else { return }
            pasteboard.setString(editing.selectedText)
        case .cut:
            guard editing.hasSelection else { return }
            pasteboard.setString(editing.selectedText)
            change { $0.delete(.characterBackward) }
        case .paste:
            // One line: line breaks become spaces, as a single-line text field takes them.
            guard let pastedText = pasteboard.string()?.components(separatedBy: .newlines).joined(separator: " "), !pastedText.isEmpty else { return }
            change { $0.insert(pastedText) }
        case .undo:
            guard let previousEditing = undoSnapshots.popLast() else { return }
            redoSnapshots.append(editing)
            editing = previousEditing
            isTyping = false
        case .redo:
            guard let nextEditing = redoSnapshots.popLast() else { return }
            undoSnapshots.append(editing)
            editing = nextEditing
            isTyping = false
        case .endEditing:
            break
        }
    }

    /// Records the text as it was before a change, unless the change continues a run of typing.
    private mutating func change(isTyping continuesTyping: Bool = false, _ body: (inout SpringboardTextEditing) -> Void) {
        let editingBefore = editing
        body(&editing)
        guard editing.text != editingBefore.text else { return }
        if !(continuesTyping && isTyping) {
            undoSnapshots.append(editingBefore)
        }
        redoSnapshots.removeAll()
        isTyping = continuesTyping
    }
}
