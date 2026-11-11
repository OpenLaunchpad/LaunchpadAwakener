import CoreGraphics
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// What macOS 15 did when the keyboard left Launchpad (`-[Springboard lostKeyFocus:]`, 15.5 `0x10009262C`):
/// it hid for the codes 0x1000 and 0xF102, never for 0x4000, and not while text was being edited or a
/// deletion was being confirmed.
@Suite("Losing the keyboard")
@MainActor
struct SpringboardKeyFocusTests {
    @Test(
        "the focus lost hides the springboard; the focus handed to another process and other codes do not",
        arguments: [(Int64(0x1000), true), (0xF102, true), (0x4000, false), (0x8000, false), (0, false)]
    )
    func codes(code: Int64, hides: Bool) {
        #expect(SpringboardKeyFocus.hidesSpringboard(notificationCode: code, isEditingText: false, isAskingToDelete: false) == hides)
    }

    @Test("it stays while text is being edited, as 15 did")
    func staysWhileEditingText() {
        #expect(!SpringboardKeyFocus.hidesSpringboard(notificationCode: SpringboardKeyFocus.lostCode, isEditingText: true, isAskingToDelete: false))
    }

    /// The text input helper shows the confirmation in its own window and takes the keyboard for it.
    @Test("it stays while a deletion is being confirmed, as 15 did for its alert")
    func staysWhileConfirmingDeletion() {
        #expect(!SpringboardKeyFocus.hidesSpringboard(notificationCode: SpringboardKeyFocus.lostCode, isEditingText: false, isAskingToDelete: true))
    }

    @Test("a type 21 event is read as a key focus notification with its code and the other process")
    func readsKeyFocusNotifications() throws {
        let event = try #require(CGEvent(source: nil))
        event.type = try #require(CGEventType(rawValue: SpringboardKeyFocus.notificationEventType))
        event.setIntegerValueField(Self.field(SpringboardKeyFocus.codeField), value: SpringboardKeyFocus.handedToAnotherProcessCode)
        event.setIntegerValueField(Self.field(SpringboardKeyFocus.otherProcessField), value: 512)

        let inputEvent = SpringboardInputEvent(event: event, eventType: SpringboardKeyFocus.notificationEventType)
        #expect(inputEvent.kind == .keyFocusNotification(code: 0x4000, otherProcessIdentifier: 512))
    }

    @Test("the search field counts as edited once it holds text, not before")
    func searchFieldEditing() {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        #expect(!interface.isEditingText)

        _ = interface.handleKeyDown(keyCode: 0, characters: "a", modifierFlags: [])

        #expect(interface.isEditingText)
    }

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

    private static func field(_ rawField: UInt32) -> CGEventField {
        unsafeBitCast(rawField, to: CGEventField.self)
    }
}
