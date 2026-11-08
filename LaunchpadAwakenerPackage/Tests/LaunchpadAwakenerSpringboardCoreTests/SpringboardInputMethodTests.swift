import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// Typing through the system's input methods, as the standalone app does: what is being composed stands
/// in for the selection, underlined, and becomes text only when the input method commits it — the way an
/// `NSTextView` behaves and 15's hosted text fields behaved.
@Suite("Input methods")
@MainActor
struct SpringboardInputMethodTests {
    // MARK: - The editing model

    @Test("composed text shows in place of the selection and is not part of the text")
    func composingStandsInForTheSelection() {
        var editing = SpringboardTextEditing(selectingAllOf: "Apps")
        editing.placeCaret(at: 1)
        editing.placeCaret(at: 3, extendingSelection: true)
        editing.setMarkedText("ni", selectedRange: 2..<2)
        #expect(editing.text == "Apps")
        #expect(editing.displayText == "Anis")
        #expect(editing.displayMarkedRange == 1..<3)
        #expect(editing.displayCaretOffset == 3)
        #expect(!editing.displaysSelection)
    }

    @Test("committing takes the composed text as typed, in place of the selection")
    func committingTypesTheComposedText() {
        var editing = SpringboardTextEditing(selectingAllOf: "Apps")
        editing.setMarkedText("日历", selectedRange: 2..<2)
        editing.commitMarkedText()
        #expect(editing.text == "日历")
        #expect(!editing.hasMarkedText)
        #expect(editing.caretOffset == 2)
    }

    @Test("typing while composing replaces what was composed, as an input method's commit does")
    func insertingReplacesTheComposedText() {
        var editing = SpringboardTextEditing(selectingAllOf: "")
        editing.setMarkedText("rili", selectedRange: 4..<4)
        editing.insert("日历")
        #expect(editing.text == "日历")
        #expect(editing.displayText == "日历")
        #expect(!editing.hasMarkedText)
    }

    @Test("an empty composition ends composing and leaves the text as it was")
    func emptyCompositionEndsComposing() {
        var editing = SpringboardTextEditing(selectingAllOf: "Apps")
        editing.setMarkedText("n", selectedRange: 1..<1)
        editing.setMarkedText("", selectedRange: 0..<0)
        #expect(!editing.hasMarkedText)
        #expect(editing.displayText == "Apps")
        #expect(editing.displaysSelection)
    }

    @Test("undoing after a commit goes back to the text before composing, not to a half-typed word")
    func undoSkipsTheComposition() {
        var editor = SpringboardFieldEditor(editing: SpringboardTextEditing(selectingAllOf: ""))
        editor.setMarkedText("ri", selectedRange: 2..<2)
        editor.setMarkedText("rili", selectedRange: 4..<4)
        editor.commitMarkedText()
        editor.apply(.undo, pasteboard: UnusedPasteboard())
        #expect(editor.editing.displayText == "")
        #expect(!editor.editing.hasMarkedText)
    }

    // MARK: - Counting as AppKit does

    @Test("a Chinese name and an emoji count one character each but take more UTF-16 units")
    func utf16Ranges() {
        let text = "a👍🏽日历"
        #expect(SpringboardTextEditing.utf16Range(ofCharacters: 1..<2, in: text) == NSRange(location: 1, length: 4))
        #expect(SpringboardTextEditing.utf16Range(ofCharacters: 2..<4, in: text) == NSRange(location: 5, length: 2))
    }

    @Test("a UTF-16 range cutting through an emoji widens to the whole character")
    func utf16RangeWidensToWholeCharacters() {
        let text = "a👍🏽b"
        #expect(SpringboardTextEditing.characterRange(ofUTF16Range: NSRange(location: 2, length: 1), in: text) == 1..<2)
        #expect(SpringboardTextEditing.characterRange(ofUTF16Range: NSRange(location: 5, length: 0), in: text) == 2..<2)
    }

    // MARK: - The interface as the input methods' client

    private static func makeInterface() -> SpringboardInterface {
        let metrics = SpringboardMetrics(SpringboardMetrics.Input(
            screenSize: CGSize(width: 1470, height: 956),
            dockOrientation: .bottom,
            dockThickness: 79,
            notchHeight: 0,
            rowCount: 5,
            columnCount: 7,
            zoomStyle: 0,
            labelLineHeight: 16
        ))
        return SpringboardInterface(layout: .empty, metrics: metrics, scale: 2, rootLayer: CALayer(), applyEdit: { _ in })
    }

    @Test("composing in the search field shows the composition there without searching for it")
    func composingInTheSearchField() {
        let interface = Self.makeInterface()
        interface.inputMethodSetMarkedText("rili", selectedUTF16Range: NSRange(location: 4, length: 0))
        #expect(interface.inputMethodText == "rili")
        #expect(interface.inputMethodMarkedRange == NSRange(location: 0, length: 4))
        #expect(interface.inputMethodSelectedRange == NSRange(location: 4, length: 0))
    }

    @Test("what the input method commits is typed into the search field")
    func committingIntoTheSearchField() {
        let interface = Self.makeInterface()
        interface.inputMethodSetMarkedText("rili", selectedUTF16Range: NSRange(location: 4, length: 0))
        interface.inputMethodInsert("日历")
        #expect(interface.inputMethodText == "日历")
        #expect(interface.inputMethodMarkedRange == nil)
        #expect(interface.inputMethodSelectedRange == NSRange(location: 2, length: 0))
    }

    @Test("a press takes what is being composed as typed")
    func pressCommitsTheComposition() {
        let interface = Self.makeInterface()
        interface.inputMethodSetMarkedText("rili", selectedUTF16Range: NSRange(location: 4, length: 0))
        _ = interface.handleMouseDown(at: CGPoint(x: 700, y: 400), timestamp: 0)
        #expect(interface.inputMethodText == "rili")
        #expect(interface.inputMethodMarkedRange == nil)
    }

    @Test("the caret the candidate window goes under is in the search field")
    func caretRectIsInTheSearchField() throws {
        let interface = Self.makeInterface()
        interface.inputMethodSetMarkedText("ni", selectedUTF16Range: NSRange(location: 2, length: 0))
        let caretRect = try #require(interface.inputMethodCaretRect())
        // The field is laid out in the springboard layer, which starts above the room left for the Dock.
        let springboardOrigin = interface.metrics.springboardFrame.origin
        let searchFieldFrame = interface.metrics.searchFieldFrame.offsetBy(dx: springboardOrigin.x, dy: springboardOrigin.y)
        #expect(searchFieldFrame.insetBy(dx: -1, dy: -1).contains(caretRect), "caret at \(caretRect)")
    }
}

/// The pasteboard is never reached by these edits.
private struct UnusedPasteboard: SpringboardPasteboard {
    func string() -> String? {
        nil
    }

    func setString(_ string: String) {}
}
