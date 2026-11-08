import CoreGraphics
@testable import LaunchpadAwakenerPayloadCore
import QuartzCore
import Testing

/// Which keys macOS 15's search field took (`-[ECSBLayer keyDown:]`, 15.5 `0x100081AB0`): any key but
/// Tab, Return, Enter, Escape, Up and Down activates it; Left moves its caret while it has the focus,
/// Right only then and with something typed; Command-arrows stay the pages'.
@Suite("Keys in the search field")
@MainActor
struct SpringboardSearchFieldKeyTests {
    private static func makeInterface() -> SpringboardInterface {
        let metrics = SpringboardMetrics(
            SpringboardMetrics.Input(
                screenSize: CGSize(width: 1470, height: 956),
                dockOrientation: .bottom,
                dockThickness: 79,
                notchHeight: 0,
                rowCount: 5,
                columnCount: 7,
                zoomStyle: 0,
                labelLineHeight: 16
            )
        )
        return SpringboardInterface(layout: .empty, metrics: metrics, scale: 2, rootLayer: CALayer(), applyEdit: { _ in })
    }

    private static func type(_ characters: String, keyCode: Int64 = 0, modifierFlags: CGEventFlags = [], into interface: SpringboardInterface) {
        _ = interface.handleKeyDown(keyCode: keyCode, characters: characters, modifierFlags: modifierFlags)
    }

    @Test("typing goes in at the caret, which Left moves while the field has the focus")
    func leftMovesCaret() {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        Self.type("a", into: interface)
        Self.type("b", into: interface)
        Self.type("", keyCode: SpringboardKeyCode.leftArrow, into: interface)
        Self.type("X", into: interface)
        #expect(interface.searchFieldEditing.text == "aXb")
        #expect(interface.searchFieldEditing.caretOffset == 2)
    }

    @Test("without the focus Left is the grid's, and the caret stays")
    func leftWithoutFocus() {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        Self.type("a", into: interface)
        Self.type("\t", keyCode: SpringboardKeyCode.tab, into: interface)
        Self.type("", keyCode: SpringboardKeyCode.leftArrow, into: interface)
        #expect(interface.searchFieldEditing.caretOffset == 1)
    }

    @Test("Shift-Left selects, and Delete takes the selection out")
    func selectAndDelete() {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        for character in ["S", "a", "f"] {
            Self.type(character, into: interface)
        }
        Self.type("", keyCode: SpringboardKeyCode.leftArrow, modifierFlags: .maskShift, into: interface)
        Self.type("", keyCode: SpringboardKeyCode.leftArrow, modifierFlags: .maskShift, into: interface)
        #expect(interface.searchFieldEditing.selectedRange == 1..<3)
        Self.type("\u{7F}", keyCode: SpringboardKeyCode.delete, into: interface)
        #expect(interface.searchFieldEditing.text == "S")
    }

    @Test("Command-Z takes the typing back")
    func undo() {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        Self.type("a", into: interface)
        Self.type("b", into: interface)
        Self.type("z", keyCode: 6, modifierFlags: .maskCommand, into: interface)
        #expect(interface.searchFieldEditing.text == "")
    }

    @Test("Up and Down are never the field's")
    func upAndDown() {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        Self.type("a", into: interface)
        Self.type("b", into: interface)
        Self.type("", keyCode: SpringboardKeyCode.upArrow, into: interface)
        #expect(interface.searchFieldEditing.caretOffset == 2)
    }
}
