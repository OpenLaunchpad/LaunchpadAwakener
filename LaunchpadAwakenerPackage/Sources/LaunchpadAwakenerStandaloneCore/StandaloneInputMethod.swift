import AppKit
import LaunchpadAwakenerSpringboardCore

/// The system's input methods for the standalone springboard's search and rename fields.
///
/// The springboard draws its fields itself, so the window's content view stands in for a text view: it is
/// the first responder, conforms to `NSTextInputClient`, and so has AppKit's `NSTextInputContext`. The
/// springboard offers it the keys that would type into a field; the context hands them to the input
/// method, which composes or types through the callbacks below, and those go back to the springboard.
@MainActor
final class StandaloneInputMethod: SpringboardInputMethod {
    static let shared = StandaloneInputMethod()

    weak var client: (any SpringboardInputMethodClient)?
    /// The showing window's content view, through which the input methods are reached.
    weak var contentView: StandaloneSpringboardContentView?

    func handleCurrentEvent() -> Bool {
        contentView?.offerCurrentEventToInputMethod() ?? false
    }

    func discardComposition() {
        contentView?.inputContext?.discardMarkedText()
    }
}

/// The springboard window's content view: hosts the springboard's layers, takes the keyboard, and is the
/// text input client the input methods type into.
final class StandaloneSpringboardContentView: NSView, @MainActor NSTextInputClient {
    /// The event being handled, while the window hands it to the springboard.
    var currentEvent: NSEvent?
    /// Set while an offered key is with the input method: whether it typed or composed, and whether it
    /// turned the key into a command instead.
    private var didTypeOrCompose = false
    private var didTurnKeyIntoCommand = false

    override var acceptsFirstResponder: Bool {
        true
    }

    private var client: (any SpringboardInputMethodClient)? {
        StandaloneInputMethod.shared.client
    }

    /// Gives the event being handled to the input context, as a text view's `keyDown(with:)` does: first
    /// the input method, then the key bindings. Returns whether it typed or composed; a key turned into a
    /// command stays the springboard's, which knows 15's rules for it.
    func offerCurrentEventToInputMethod() -> Bool {
        guard let currentEvent, let inputContext else { return false }
        didTypeOrCompose = false
        didTurnKeyIntoCommand = false
        let isHandledByInputMethod = inputContext.handleEvent(currentEvent)
        if !isHandledByInputMethod, currentEvent.type == .keyDown {
            interpretKeyEvents([currentEvent])
        }
        if didTurnKeyIntoCommand {
            return false
        }
        return isHandledByInputMethod || didTypeOrCompose
    }

    override func doCommand(by selector: Selector) {
        didTurnKeyIntoCommand = true
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        didTypeOrCompose = true
        client?.inputMethodInsert(Self.plainString(of: string))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        didTypeOrCompose = true
        client?.inputMethodSetMarkedText(Self.plainString(of: string), selectedUTF16Range: selectedRange)
    }

    func unmarkText() {
        client?.inputMethodCommitMarkedText()
    }

    func selectedRange() -> NSRange {
        client?.inputMethodSelectedRange ?? NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        client?.inputMethodMarkedRange ?? NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        client?.inputMethodMarkedRange != nil
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let text = client?.inputMethodText else { return nil }
        let availableRange = NSIntersectionRange(range, NSRange(location: 0, length: (text as NSString).length))
        actualRange?.pointee = availableRange
        return NSAttributedString(string: (text as NSString).substring(with: availableRange))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// The caret, in screen coordinates. The springboard's container is laid out from the bottom left of
    /// the display it shows on, so it only moves by where that screen is.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let caretRect = client?.inputMethodCaretRect() else { return .zero }
        let screenOrigin = window?.screen?.frame.origin ?? .zero
        return caretRect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y)
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    private static func plainString(of string: Any) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }
}
