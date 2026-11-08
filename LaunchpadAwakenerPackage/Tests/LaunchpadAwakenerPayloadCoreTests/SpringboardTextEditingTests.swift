import CoreGraphics
@testable import LaunchpadAwakenerPayloadCore
import Testing

/// Editing a folder's name the way macOS 15's rename field, a real text field, edited it. Its behaviour was
/// read from 15.5's `com.apple.dock.ecti` service and checked against the 15.5 virtual machine: the name
/// starts out selected, Left and Right collapse the selection, the arrows move the caret.
@Suite("Editing a folder's name")
struct SpringboardTextEditingTests {
    // MARK: - The selection and the caret

    @Test("renaming starts with the whole name selected, and typing replaces it")
    func typingReplacesTheSelectedName() {
        var editing = SpringboardTextEditing(selectingAllOf: "效率")
        #expect(editing.selectedRange == 0..<2)

        editing.insert("工具")

        #expect(editing.text == "工具")
        #expect(editing.selectedRange == 2..<2)
    }

    @Test("Left and Right collapse a selection to the end they point at")
    func arrowsCollapseTheSelection() {
        var movedLeft = SpringboardTextEditing(selectingAllOf: "Utilities")
        var movedRight = movedLeft

        movedLeft.move(.characterBackward, extendingSelection: false)
        movedRight.move(.characterForward, extendingSelection: false)

        #expect(movedLeft.selectedRange == 0..<0)
        #expect(movedRight.selectedRange == 9..<9)
    }

    @Test("the caret steps over whole characters, never into a Chinese character, an emoji or an accent")
    func caretStepsOverWholeCharacters() {
        var editing = SpringboardTextEditing(selectingAllOf: "效率👨‍👩‍👧e\u{301}")
        editing.move(.lineEnd, extendingSelection: false)

        editing.move(.characterBackward, extendingSelection: false)
        editing.move(.characterBackward, extendingSelection: false)
        editing.insert("x")

        #expect(editing.text == "效率x👨‍👩‍👧e\u{301}")
    }

    @Test("Option-Left goes back a word at a time")
    func optionLeftMovesByWord() {
        var editing = SpringboardTextEditing(selectingAllOf: "Developer Tools 2")
        editing.move(.lineEnd, extendingSelection: false)
        var caretOffsets: [Int] = []

        for _ in 0..<3 {
            editing.move(.wordBackward, extendingSelection: false)
            caretOffsets.append(editing.caretOffset)
        }

        #expect(caretOffsets == [16, 10, 0])
    }

    @Test("Option-Right goes on to the end of each word")
    func optionRightMovesByWord() {
        var editing = SpringboardTextEditing(selectingAllOf: "Developer Tools 2")
        editing.move(.lineStart, extendingSelection: false)
        var caretOffsets: [Int] = []

        for _ in 0..<3 {
            editing.move(.wordForward, extendingSelection: false)
            caretOffsets.append(editing.caretOffset)
        }

        #expect(caretOffsets == [9, 15, 17])
    }

    @Test("Shift moves the selection's far end and keeps where it began")
    func shiftExtendsFromWhereTheSelectionBegan() {
        var editing = SpringboardTextEditing(selectingAllOf: "Utilities")
        editing.placeCaret(at: 4)

        editing.move(.characterForward, extendingSelection: true)
        editing.move(.wordForward, extendingSelection: true)
        editing.move(.characterBackward, extendingSelection: true)

        #expect(editing.selectedRange == 4..<8)
    }

    @Test("Shift-Left after the name was selected gives up its last character")
    func shiftLeftShrinksTheInitialSelection() {
        var editing = SpringboardTextEditing(selectingAllOf: "Utilities")

        editing.move(.characterBackward, extendingSelection: true)

        #expect(editing.selectedRange == 0..<8)
    }

    @Test("a double-click selects the word under it, or the space between two words")
    func doubleClickSelectsAWord() {
        let editing = SpringboardTextEditing(selectingAllOf: "Developer Tools 2")

        #expect(editing.wordRange(atCharacterOffset: 12) == 10..<15)
        #expect(editing.wordRange(atCharacterOffset: 9) == 9..<10)
    }

    // MARK: - Deleting

    @Test("Delete takes the character before the caret, a whole emoji at once")
    func deleteTakesAWholeCharacter() {
        var editing = SpringboardTextEditing(selectingAllOf: "效率👨‍👩‍👧")
        editing.move(.lineEnd, extendingSelection: false)

        editing.delete(.characterBackward)

        #expect(editing.text == "效率")
    }

    @Test("any deletion takes the selection when there is one")
    func deletionTakesTheSelection() {
        var editing = SpringboardTextEditing(selectingAllOf: "Developer Tools")
        editing.select(10..<15)

        editing.delete(.wordBackward)

        #expect(editing.text == "Developer ")
        #expect(editing.selectedRange == 10..<10)
    }

    @Test("from the end, Option-Delete takes the last word, Command-Delete everything, Delete a character", arguments: [
        (SpringboardTextEditing.Deletion.wordBackward, "Developer "),
        (.toLineStart, ""),
        (.characterBackward, "Developer Tool"),
    ])
    func deletionsBackFromTheEnd(deletion: SpringboardTextEditing.Deletion, remainingText: String) {
        var editing = SpringboardTextEditing(selectingAllOf: "Developer Tools")
        editing.move(.lineEnd, extendingSelection: false)

        editing.delete(deletion)

        #expect(editing.text == remainingText)
    }

    @Test("forward delete takes the character after the caret")
    func forwardDeleteTakesTheNextCharacter() {
        var editing = SpringboardTextEditing(selectingAllOf: "效率")
        editing.move(.lineStart, extendingSelection: false)

        editing.delete(.characterForward)

        #expect(editing.text == "率")
        #expect(editing.caretOffset == 0)
    }

    // MARK: - Keys

    @Test("keys are read as 15's text field read them", arguments: [
        (SpringboardKeyCode.leftArrow, CGEventFlags(), SpringboardTextEditingCommand.move(.characterBackward, extendingSelection: false)),
        (SpringboardKeyCode.leftArrow, .maskAlternate, .move(.wordBackward, extendingSelection: false)),
        (SpringboardKeyCode.leftArrow, [.maskCommand, .maskShift], .move(.lineStart, extendingSelection: true)),
        (SpringboardKeyCode.rightArrow, [.maskAlternate, .maskShift], .move(.wordForward, extendingSelection: true)),
        (SpringboardKeyCode.upArrow, [], .move(.lineStart, extendingSelection: false)),
        (SpringboardKeyCode.downArrow, .maskShift, .move(.lineEnd, extendingSelection: true)),
        (SpringboardKeyCode.delete, .maskAlternate, .delete(.wordBackward)),
        (SpringboardKeyCode.delete, .maskCommand, .delete(.toLineStart)),
        (SpringboardKeyCode.forwardDelete, [], .delete(.characterForward)),
        (SpringboardKeyCode.returnKey, [], .endEditing),
        (SpringboardKeyCode.escape, [], .endEditing),
    ] as [(Int64, CGEventFlags, SpringboardTextEditingCommand)])
    func keysAreReadAsCommands(keyCode: Int64, modifierFlags: CGEventFlags, command: SpringboardTextEditingCommand) {
        #expect(SpringboardTextEditingCommand(keyCode: keyCode, characters: "", modifierFlags: modifierFlags) == command)
    }

    @Test("Command-A selects everything, other Command shortcuts and Tab do nothing, other keys type")
    func shortcutsAndTyping() {
        #expect(SpringboardTextEditingCommand(keyCode: 0, characters: "a", modifierFlags: .maskCommand) == .selectAll)
        #expect(SpringboardTextEditingCommand(keyCode: 9, characters: "v", modifierFlags: .maskCommand) == nil)
        #expect(SpringboardTextEditingCommand(keyCode: SpringboardKeyCode.tab, characters: "\t", modifierFlags: []) == nil)
        #expect(SpringboardTextEditingCommand(keyCode: 0, characters: "å", modifierFlags: .maskAlternate) == .insert("å"))
    }

    // MARK: - Where the caret stands

    @Test("「效率」 sets as wide as 15.5's field selected it, 53 points, each character half of it")
    func chineseNameIsAsWideAsInFifteen() {
        // The selection measured 106 pixels at 2x in a screenshot of the 15.5 virtual machine.
        let textLine = SpringboardTextLine(text: "效率", font: SpringboardTypography.folderTitleFont)

        #expect(abs(textLine.width - 53) < 1)
        #expect(abs(textLine.caretXOffsets[1] * 2 - textLine.width) < 0.5)
    }

    @Test("a click puts the caret at the nearer side of the character it lands on")
    func clickPutsTheCaretOnTheNearerSide() {
        let textLine = SpringboardTextLine(text: "效率 ok", font: SpringboardTypography.folderTitleFont)
        let firstCharacterMiddle = (textLine.caretXOffsets[0] + textLine.caretXOffsets[1]) / 2

        #expect(textLine.caretOffset(nearestTo: firstCharacterMiddle - 1) == 0)
        #expect(textLine.caretOffset(nearestTo: firstCharacterMiddle + 1) == 1)
        #expect(textLine.caretOffset(nearestTo: textLine.width + 50) == 5)
    }

    @Test("the character under a point is the one whose width it falls in, or the last past the end")
    func characterUnderAPoint() {
        let textLine = SpringboardTextLine(text: "效率", font: SpringboardTypography.folderTitleFont)
        let firstCharacterEnd = textLine.caretXOffsets[1]

        #expect(textLine.characterOffset(at: firstCharacterEnd - 1) == 0)
        #expect(textLine.characterOffset(at: firstCharacterEnd + 1) == 1)
        #expect(textLine.characterOffset(at: 200) == 1)
    }

    // MARK: - Scrolling

    @Test("a name that fits is centred, trailing spaces hanging past the middle")
    func fittingNameIsCentred() {
        let withoutSpace = SpringboardTitleEditorLayer.linePlacement(lineWidth: 100, trailingWhitespaceWidth: 0, caretX: 100, areaWidth: 300, scrollOffset: 0)
        let withSpace = SpringboardTitleEditorLayer.linePlacement(lineWidth: 110, trailingWhitespaceWidth: 10, caretX: 110, areaWidth: 300, scrollOffset: 0)

        #expect(withoutSpace.lineStartX == 100)
        #expect(withSpace.lineStartX == 100)
    }

    @Test("a name too long for the field scrolls just enough to keep the caret in view")
    func longNameScrollsWithTheCaret() {
        // 500 points of text in a 300-point field, the caret 2 points wide.
        let atEnd = SpringboardTitleEditorLayer.linePlacement(lineWidth: 500, trailingWhitespaceWidth: 0, caretX: 500, areaWidth: 300, scrollOffset: 0)
        let backAWord = SpringboardTitleEditorLayer.linePlacement(lineWidth: 500, trailingWhitespaceWidth: 0, caretX: 400, areaWidth: 300, scrollOffset: atEnd.scrollOffset)
        let atStart = SpringboardTitleEditorLayer.linePlacement(lineWidth: 500, trailingWhitespaceWidth: 0, caretX: 0, areaWidth: 300, scrollOffset: backAWord.scrollOffset)

        #expect(atEnd.lineStartX == -202)
        #expect(backAWord.lineStartX == -202)
        #expect(atStart.lineStartX == 0)
    }
}
