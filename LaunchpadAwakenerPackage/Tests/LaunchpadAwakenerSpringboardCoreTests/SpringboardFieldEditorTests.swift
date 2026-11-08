import CoreGraphics
@testable import LaunchpadAwakenerSpringboardCore
import Testing

/// Copying, pasting and undoing in the search and rename fields, the standard behaviour of the text
/// fields macOS 15 hosted for them.
@Suite("Field editing with the pasteboard and undo")
struct SpringboardFieldEditorTests {
    /// The general pasteboard, kept in memory.
    private final class InMemoryPasteboard: SpringboardPasteboard {
        var storedString: String?

        func string() -> String? {
            storedString
        }

        func setString(_ string: String) {
            storedString = string
        }
    }

    private static func editor(_ text: String) -> SpringboardFieldEditor {
        SpringboardFieldEditor(editing: SpringboardTextEditing(selectingAllOf: text))
    }

    @Test(
        "Command-C, X, V, Z and Shift-Command-Z are read as the edit commands",
        arguments: [
            ("c", CGEventFlags.maskCommand, SpringboardTextEditingCommand.copy),
            ("x", .maskCommand, .cut),
            ("v", .maskCommand, .paste),
            ("z", .maskCommand, .undo),
            ("Z", [.maskCommand, .maskShift], .redo),
        ] as [(String, CGEventFlags, SpringboardTextEditingCommand)]
    )
    func editCommands(characters: String, modifierFlags: CGEventFlags, expectedCommand: SpringboardTextEditingCommand) {
        #expect(SpringboardTextEditingCommand(keyCode: 0, characters: characters, modifierFlags: modifierFlags) == expectedCommand)
    }

    @Test("copy puts the selection on the pasteboard and keeps the text")
    func copy() {
        let pasteboard = InMemoryPasteboard()
        var editor = Self.editor("Utilities")
        editor.apply(.copy, pasteboard: pasteboard)
        #expect(pasteboard.storedString == "Utilities")
        #expect(editor.editing.text == "Utilities")
    }

    @Test("cut takes the selection out, paste puts the pasteboard's text in at the caret")
    func cutAndPaste() {
        let pasteboard = InMemoryPasteboard()
        var editor = Self.editor("Developer Tools")
        editor.apply(.move(.characterBackward, extendingSelection: false), pasteboard: pasteboard)
        editor.apply(.move(.wordForward, extendingSelection: true), pasteboard: pasteboard)
        editor.apply(.cut, pasteboard: pasteboard)
        #expect(pasteboard.storedString == "Developer")
        #expect(editor.editing.text == " Tools")

        editor.apply(.move(.lineEnd, extendingSelection: false), pasteboard: pasteboard)
        editor.apply(.paste, pasteboard: pasteboard)
        #expect(editor.editing.text == " ToolsDeveloper")
    }

    @Test("a pasted line break is left out, the field holding one line")
    func pasteOneLine() {
        let pasteboard = InMemoryPasteboard()
        pasteboard.storedString = "Mail\nNotes"
        var editor = Self.editor("")
        editor.apply(.paste, pasteboard: pasteboard)
        #expect(editor.editing.text == "Mail Notes")
    }

    @Test("undo takes back a run of typing at once, and redo puts it back")
    func undoTyping() {
        let pasteboard = InMemoryPasteboard()
        var editor = Self.editor("")
        for character in ["S", "a", "f"] {
            editor.apply(.insert(character), pasteboard: pasteboard)
        }
        editor.apply(.undo, pasteboard: pasteboard)
        #expect(editor.editing.text == "")
        editor.apply(.redo, pasteboard: pasteboard)
        #expect(editor.editing.text == "Saf")
    }

    @Test("moving the caret ends a run of typing, so undo goes back one run at a time")
    func undoStepsByRun() {
        let pasteboard = InMemoryPasteboard()
        var editor = Self.editor("")
        editor.apply(.insert("a"), pasteboard: pasteboard)
        editor.apply(.insert("b"), pasteboard: pasteboard)
        editor.apply(.move(.lineStart, extendingSelection: false), pasteboard: pasteboard)
        editor.apply(.insert("c"), pasteboard: pasteboard)
        #expect(editor.editing.text == "cab")
        editor.apply(.undo, pasteboard: pasteboard)
        #expect(editor.editing.text == "ab")
        editor.apply(.undo, pasteboard: pasteboard)
        #expect(editor.editing.text == "")
    }

    @Test("a deletion is a step of its own")
    func undoDeletion() {
        let pasteboard = InMemoryPasteboard()
        var editor = Self.editor("")
        editor.apply(.insert("a"), pasteboard: pasteboard)
        editor.apply(.insert("b"), pasteboard: pasteboard)
        editor.apply(.delete(.characterBackward), pasteboard: pasteboard)
        #expect(editor.editing.text == "a")
        editor.apply(.undo, pasteboard: pasteboard)
        #expect(editor.editing.text == "ab")
    }
}
