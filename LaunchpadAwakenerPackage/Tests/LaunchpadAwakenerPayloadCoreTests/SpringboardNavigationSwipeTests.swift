import CoreGraphics
@testable import LaunchpadAwakenerPayloadCore
import Testing

/// Expected values are read off macOS 15.5's disassembly: `-[ECEvent navigationGestureType]`
/// (`0x10010B89C`) turns the swipe's motion and direction flag into a type from 0 to 3, and
/// `-[ECPagerLayer gesture:]` (`0x1000B78BC`) turns types 1 and 3 into the next page, 0 and 2 into the
/// previous one.
@Suite("Turning pages with a three-finger swipe")
struct SpringboardNavigationSwipeTests {
    @Test(
        "each swipe with a direction turns one page, as macOS 15.5 did",
        arguments: [
            (Int64(1), false, 1), // type 1
            (Int64(2), false, -1), // type 0
            (Int64(8), false, 1), // type 3
            (Int64(8), true, -1), // type 2
            (Int64(4), false, -1), // type 2
            (Int64(4), true, 1), // type 3
        ]
    )
    func pageOffset(motion: Int64, directionFlag: Bool, expectedOffset: Int) {
        let navigationSwipe = SpringboardInputEvent.NavigationSwipe(motion: motion, directionFlag: directionFlag)
        #expect(navigationSwipe.pageOffset == expectedOffset)
    }

    @Test("a swipe without a recognised direction turns nothing", arguments: [Int64(0), 3, 5, 16])
    func noDirection(motion: Int64) {
        #expect(SpringboardInputEvent.NavigationSwipe(motion: motion, directionFlag: false).pageOffset == nil)
    }

    @Test("a gesture event of HID type 16 is read as a navigation swipe")
    func readsNavigationSwipeEvents() throws {
        let event = try Self.makeGestureEvent()
        event.setIntegerValueField(Self.field(110), value: 16)
        event.setIntegerValueField(Self.field(115), value: 8)
        event.setIntegerValueField(Self.field(136), value: 1)

        let inputEvent = SpringboardInputEvent(event: event, eventType: 29)
        #expect(inputEvent.kind == .navigationSwipe(SpringboardInputEvent.NavigationSwipe(motion: 8, directionFlag: true)))
    }

    @Test("other gesture events are not")
    func ignoresOtherGestures() throws {
        let event = try Self.makeGestureEvent()
        event.setIntegerValueField(Self.field(110), value: 6)
        event.setIntegerValueField(Self.field(115), value: 8)

        #expect(SpringboardInputEvent(event: event, eventType: 29).kind == .other(eventType: 29))
    }

    /// The gesture fields only stick to an event of the gesture type, 29.
    private static func makeGestureEvent() throws -> CGEvent {
        let event = try #require(CGEvent(source: nil))
        event.type = try #require(CGEventType(rawValue: 29))
        return event
    }

    private static func field(_ rawField: UInt32) -> CGEventField {
        unsafeBitCast(rawField, to: CGEventField.self)
    }
}
