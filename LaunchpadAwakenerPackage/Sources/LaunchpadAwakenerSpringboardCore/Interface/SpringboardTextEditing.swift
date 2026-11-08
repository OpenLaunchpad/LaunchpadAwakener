import CoreGraphics
import CoreText
import Foundation

/// A line of text being edited and its selection, as the field editor behind macOS 15's rename field kept
/// them. That field was a real `NSTextField`, hosted for the Dock by its `com.apple.dock.ecti` service.
///
/// Offsets count characters as the user sees them, so a Chinese character or an emoji sequence is never
/// split. The selection runs from `anchorOffset`, where it began, to `caretOffset`, the end that moves;
/// when the two are equal nothing is selected and the caret stands there.
struct SpringboardTextEditing: Equatable, Sendable {
    enum Movement: Equatable, Sendable {
        case characterBackward
        case characterForward
        case wordBackward
        case wordForward
        case lineStart
        case lineEnd
    }

    enum Deletion: Equatable, Sendable {
        case characterBackward
        case characterForward
        case wordBackward
        case wordForward
        case toLineStart
    }

    private(set) var text: String
    private(set) var anchorOffset: Int
    private(set) var caretOffset: Int
    /// Text an input method is composing. It stands in for the selection on screen until the input method
    /// commits it, and is not part of `text` till then, so nothing is searched for or stored half typed.
    private(set) var markedText: String?
    /// The input method's own selection within ``markedText``, where it shows the caret.
    private(set) var markedSelectedRange: Range<Int> = 0..<0

    /// All of `text` selected, as 15's field began: its service selected the text as soon as the field was
    /// set up (`-[ECTIHelperDelegate _handleSetupMessage:forPeer:]`, 15.5 `0x100001198`).
    init(selectingAllOf text: String) {
        self.text = text
        anchorOffset = 0
        caretOffset = text.count
    }

    var selectedRange: Range<Int> {
        min(anchorOffset, caretOffset)..<max(anchorOffset, caretOffset)
    }

    var hasSelection: Bool {
        anchorOffset != caretOffset
    }

    /// What is selected, as the pasteboard gets it.
    var selectedText: String {
        let characters = Array(text)
        return String(characters[selectedRange])
    }

    // MARK: - Typing and deleting

    /// Replaces the selection with `insertedText`, or inserts it at the caret, and leaves the caret after it.
    mutating func insert(_ insertedText: String) {
        replaceCharacters(in: selectedRange, with: insertedText)
    }

    /// Deletes the selection if there is one, whichever deletion it is, as a text field does; otherwise the
    /// stretch `deletion` names, from the caret.
    mutating func delete(_ deletion: Deletion) {
        guard !hasSelection else {
            replaceCharacters(in: selectedRange, with: "")
            return
        }
        let deletedRange = switch deletion {
        case .characterBackward: max(caretOffset - 1, 0)..<caretOffset
        case .characterForward: caretOffset..<min(caretOffset + 1, text.count)
        case .wordBackward: wordStart(before: caretOffset)..<caretOffset
        case .wordForward: caretOffset..<wordEnd(after: caretOffset)
        case .toLineStart: 0..<caretOffset
        }
        replaceCharacters(in: deletedRange, with: "")
    }

    private mutating func replaceCharacters(in range: Range<Int>, with replacement: String) {
        // Any change to the text ends composing; committing replaces the selection the composed text stood in for.
        markedText = nil
        markedSelectedRange = 0..<0
        let lowerIndex = text.index(text.startIndex, offsetBy: range.lowerBound)
        let upperIndex = text.index(text.startIndex, offsetBy: range.upperBound)
        let textBeforeCaret = String(text[..<lowerIndex]) + replacement
        text = textBeforeCaret + String(text[upperIndex...])
        // Counted afresh, not added up: a combining mark typed after a letter becomes part of it.
        caretOffset = min(textBeforeCaret.count, text.count)
        anchorOffset = caretOffset
    }

    // MARK: - Composing

    var hasMarkedText: Bool {
        markedText != nil
    }

    /// Starts or changes what an input method composes, `selectedRange` its selection within it in
    /// characters; empty text ends composing, as `setMarkedText:` with an empty string does.
    mutating func setMarkedText(_ composedText: String, selectedRange: Range<Int>) {
        guard !composedText.isEmpty else {
            discardMarkedText()
            return
        }
        markedText = composedText
        let upperOffset = min(max(selectedRange.upperBound, 0), composedText.count)
        let lowerOffset = min(max(selectedRange.lowerBound, 0), upperOffset)
        markedSelectedRange = lowerOffset..<upperOffset
    }

    /// Takes what was being composed as typed: `unmarkText`, which commits.
    mutating func commitMarkedText() {
        guard let markedText else { return }
        insert(markedText)
    }

    /// Drops what was being composed, leaving the text as it was.
    mutating func discardMarkedText() {
        markedText = nil
        markedSelectedRange = 0..<0
    }

    // MARK: - What a field shows

    /// The text with the composed text in place of the selection.
    var displayText: String {
        guard let markedText else { return text }
        let characters = Array(text)
        return String(characters[..<selectedRange.lowerBound]) + markedText + String(characters[selectedRange.upperBound...])
    }

    /// Where the composed text stands in ``displayText``, underlined; nil while nothing is composed.
    var displayMarkedRange: Range<Int>? {
        markedText.map { selectedRange.lowerBound..<(selectedRange.lowerBound + $0.count) }
    }

    /// The caret in ``displayText``: inside the composed text where the input method put it.
    var displayCaretOffset: Int {
        guard markedText != nil else { return caretOffset }
        return selectedRange.lowerBound + markedSelectedRange.upperBound
    }

    /// The selection in ``displayText``; while composing, none — the composed text is underlined instead.
    var displaySelectedRange: Range<Int> {
        guard markedText != nil else { return selectedRange }
        return displayCaretOffset..<displayCaretOffset
    }

    var displaysSelection: Bool {
        markedText == nil && hasSelection
    }

    /// What a field's text layer draws: the plain text, or while composing the display text with the
    /// composed part underlined, as AppKit marks text an input method is composing. A text layer ignores
    /// its own font and colour for an attributed string, so they come along.
    func displayString(font: CTFont, color: CGColor?) -> Any {
        guard let displayMarkedRange else { return text }
        let shownText = displayText
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let color {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color
        }
        let attributedString = NSMutableAttributedString(string: shownText, attributes: attributes)
        attributedString.addAttribute(
            NSAttributedString.Key(kCTUnderlineStyleAttributeName as String),
            value: CTUnderlineStyle.single.rawValue,
            range: Self.utf16Range(ofCharacters: displayMarkedRange, in: shownText)
        )
        return attributedString
    }

    // MARK: - Counting as AppKit does

    /// `characterRange`, in characters of ``displayText``, in the UTF-16 units AppKit's text input counts in.
    func displayUTF16Range(ofCharacters characterRange: Range<Int>) -> NSRange {
        Self.utf16Range(ofCharacters: characterRange, in: displayText)
    }

    /// `characterRange`, in characters of `string`, in UTF-16 units.
    static func utf16Range(ofCharacters characterRange: Range<Int>, in string: String) -> NSRange {
        let characterCount = string.count
        let lowerOffset = min(max(characterRange.lowerBound, 0), characterCount)
        let upperOffset = min(max(characterRange.upperBound, lowerOffset), characterCount)
        let lowerIndex = string.index(string.startIndex, offsetBy: lowerOffset)
        let upperIndex = string.index(string.startIndex, offsetBy: upperOffset)
        return NSRange(lowerIndex..<upperIndex, in: string)
    }

    /// `utf16Range` of `string` in whole characters, widened so that no character is split. An empty range
    /// — a caret — stays empty, at the start of the character it falls in.
    static func characterRange(ofUTF16Range utf16Range: NSRange, in string: String) -> Range<Int> {
        let utf16Count = (string as NSString).length
        let lowerUTF16Offset = min(max(utf16Range.location, 0), utf16Count)
        guard utf16Range.length > 0, lowerUTF16Offset < utf16Count else {
            let caretUTF16Offset = lowerUTF16Offset < utf16Count
                ? (string as NSString).rangeOfComposedCharacterSequence(at: lowerUTF16Offset).location
                : utf16Count
            let caretOffset = string.distance(from: string.startIndex, to: String.Index(utf16Offset: caretUTF16Offset, in: string))
            return caretOffset..<caretOffset
        }
        let upperUTF16Offset = min(max(utf16Range.location + max(utf16Range.length, 0), lowerUTF16Offset), utf16Count)
        let lowerIndex = String.Index(utf16Offset: lowerUTF16Offset, in: string)
        let upperIndex = String.Index(utf16Offset: upperUTF16Offset, in: string)
        // `rangeOfComposedCharacterSequences` widens a range that cuts through a character.
        let wholeRange = (string as NSString).rangeOfComposedCharacterSequences(for: NSRange(lowerIndex..<upperIndex, in: string))
        guard let swiftRange = Range(wholeRange, in: string) else { return 0..<0 }
        let lowerOffset = string.distance(from: string.startIndex, to: swiftRange.lowerBound)
        return lowerOffset..<(lowerOffset + string[swiftRange].count)
    }

    // MARK: - Moving and selecting

    /// Moves the caret, or with `extendingSelection` the selection's moving end. Without it the selection
    /// collapses: Left and Right to the end they point at, as `moveLeft:` and `moveRight:` do, and the
    /// longer movements set off from that end.
    mutating func move(_ movement: Movement, extendingSelection: Bool) {
        let origin: Int
        if extendingSelection || !hasSelection {
            origin = caretOffset
        } else {
            switch movement {
            case .characterBackward:
                placeCaret(at: selectedRange.lowerBound)
                return
            case .characterForward:
                placeCaret(at: selectedRange.upperBound)
                return
            case .wordBackward, .lineStart:
                origin = selectedRange.lowerBound
            case .wordForward, .lineEnd:
                origin = selectedRange.upperBound
            }
        }
        let destination = switch movement {
        case .characterBackward: max(origin - 1, 0)
        case .characterForward: min(origin + 1, text.count)
        case .wordBackward: wordStart(before: origin)
        case .wordForward: wordEnd(after: origin)
        case .lineStart: 0
        case .lineEnd: text.count
        }
        caretOffset = destination
        if !extendingSelection {
            anchorOffset = destination
        }
    }

    mutating func selectAll() {
        anchorOffset = 0
        caretOffset = text.count
    }

    /// Puts the caret at `offset` — a click — or, `extendingSelection`, moves the selection's moving end
    /// there — a Shift-click.
    mutating func placeCaret(at offset: Int, extendingSelection: Bool = false) {
        caretOffset = min(max(offset, 0), text.count)
        if !extendingSelection {
            anchorOffset = caretOffset
        }
    }

    /// Selects `range`, with the moving end at its start when `caretAtStart`, for a drag going backward.
    mutating func select(_ range: Range<Int>, caretAtStart: Bool = false) {
        let lowerOffset = min(max(range.lowerBound, 0), text.count)
        let upperOffset = min(max(range.upperBound, lowerOffset), text.count)
        anchorOffset = caretAtStart ? upperOffset : lowerOffset
        caretOffset = caretAtStart ? lowerOffset : upperOffset
    }

    // MARK: - Words

    /// The words of the text, by Foundation's word boundaries, which are dictionary based, so Chinese
    /// splits into words too.
    private var wordRanges: [Range<Int>] {
        var ranges: [Range<Int>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, wordRange, _, _ in
            ranges.append(text.distance(from: text.startIndex, to: wordRange.lowerBound)..<text.distance(from: text.startIndex, to: wordRange.upperBound))
        }
        return ranges
    }

    /// Where Option-Left goes from `offset`: the start of the word it is in, or of the one before.
    func wordStart(before offset: Int) -> Int {
        wordRanges.last { $0.lowerBound < offset }?.lowerBound ?? 0
    }

    /// Where Option-Right goes from `offset`: the end of the word it is in, or of the one after.
    func wordEnd(after offset: Int) -> Int {
        wordRanges.first { $0.upperBound > offset }?.upperBound ?? text.count
    }

    /// What a double-click on the character at `offset` selects: its word, or the run of spaces and
    /// punctuation between two words.
    func wordRange(atCharacterOffset offset: Int) -> Range<Int> {
        let words = wordRanges
        if let word = words.first(where: { $0.contains(offset) }) {
            return word
        }
        let gapStart = words.last { $0.upperBound <= offset }?.upperBound ?? 0
        let gapEnd = words.first { $0.lowerBound > offset }?.lowerBound ?? text.count
        return gapStart..<gapEnd
    }
}

/// What a key pressed while a folder is renamed does, read the way macOS 15's text fields read their
/// standard key bindings.
enum SpringboardTextEditingCommand: Equatable, Sendable {
    case insert(String)
    case move(SpringboardTextEditing.Movement, extendingSelection: Bool)
    case delete(SpringboardTextEditing.Deletion)
    case selectAll
    /// Command-C, X and V, Z and Shift-Command-Z: the Edit menu of the service that hosted 15's fields.
    case copy
    case cut
    case paste
    case undo
    case redo
    /// Return, Enter and Escape alike: 15's field ended editing on all three and kept what was typed
    /// (`-[ECTIHelperDelegate control:textView:doCommandBySelector:]`, 15.5 `0x100000FBC`).
    case endEditing

    /// The command for a key, or nil for one the field did nothing with here: Tab, Command and Control
    /// shortcuts other than the Edit menu's, function keys.
    init?(keyCode: Int64, characters: String, modifierFlags: CGEventFlags) {
        let hasCommand = modifierFlags.contains(.maskCommand)
        let hasOption = modifierFlags.contains(.maskAlternate)
        let extendsSelection = modifierFlags.contains(.maskShift)
        switch keyCode {
        case SpringboardKeyCode.returnKey, SpringboardKeyCode.keypadEnter, SpringboardKeyCode.escape:
            self = .endEditing
        case SpringboardKeyCode.leftArrow:
            self = .move(hasCommand ? .lineStart : hasOption ? .wordBackward : .characterBackward, extendingSelection: extendsSelection)
        case SpringboardKeyCode.rightArrow:
            self = .move(hasCommand ? .lineEnd : hasOption ? .wordForward : .characterForward, extendingSelection: extendsSelection)
        case SpringboardKeyCode.upArrow:
            // A single line: up goes to its start and down to its end.
            self = .move(.lineStart, extendingSelection: extendsSelection)
        case SpringboardKeyCode.downArrow:
            self = .move(.lineEnd, extendingSelection: extendsSelection)
        case SpringboardKeyCode.delete:
            self = .delete(hasCommand ? .toLineStart : hasOption ? .wordBackward : .characterBackward)
        case SpringboardKeyCode.forwardDelete:
            self = .delete(hasOption ? .wordForward : .characterForward)
        default:
            if hasCommand {
                switch (characters.lowercased(), extendsSelection) {
                case ("a", false): self = .selectAll
                case ("c", false): self = .copy
                case ("x", false): self = .cut
                case ("v", false): self = .paste
                case ("z", false): self = .undo
                case ("z", true): self = .redo
                default: return nil
                }
            } else {
                guard Self.isTypedText(characters, modifierFlags: modifierFlags) else { return nil }
                self = .insert(characters)
            }
        }
    }

    /// Whether a key's characters are text to type: no Command or Control held, and no control or
    /// function-key characters.
    static func isTypedText(_ characters: String, modifierFlags: CGEventFlags) -> Bool {
        !modifierFlags.contains(.maskCommand)
            && !modifierFlags.contains(.maskControl)
            && !characters.isEmpty
            && !characters.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) }
    }
}

/// One line of text as Core Text sets it, for putting a caret and a selection between its characters.
struct SpringboardTextLine {
    /// The typographic width, trailing spaces included.
    let width: CGFloat
    /// The width of the trailing spaces, which hang past the line when it is centred, as in a text field.
    let trailingWhitespaceWidth: CGFloat
    /// The font's ascent plus descent: how tall the caret and the selection stand, whatever the characters.
    let height: CGFloat
    /// The distance from the start of the line to each place the caret can stand, from before the first
    /// character to after the last.
    let caretXOffsets: [CGFloat]

    init(text: String, font: CTFont) {
        let attributedString = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributedString)
        width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        trailingWhitespaceWidth = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
        height = CTFontGetAscent(font) + CTFontGetDescent(font)
        var caretXOffsets = [CTLineGetOffsetForStringIndex(line, 0, nil)]
        for characterIndex in text.indices {
            let nextIndex = text.index(after: characterIndex)
            caretXOffsets.append(CTLineGetOffsetForStringIndex(line, nextIndex.utf16Offset(in: text), nil))
        }
        self.caretXOffsets = caretXOffsets
    }

    /// Where a click at `x`, a distance from the start of the line, puts the caret: the nearest place
    /// between two characters.
    func caretOffset(nearestTo x: CGFloat) -> Int {
        caretXOffsets.indices.min { abs(caretXOffsets[$0] - x) < abs(caretXOffsets[$1] - x) } ?? 0
    }

    /// The character under `x`, whose word a double-click selects; the first or last when `x` is off
    /// either end of the line.
    func characterOffset(at x: CGFloat) -> Int {
        guard caretXOffsets.count > 1 else { return 0 }
        let lastCharacterOffset = caretXOffsets.count - 2
        return (0...lastCharacterOffset).first { x < caretXOffsets[$0 + 1] } ?? lastCharacterOffset
    }
}
