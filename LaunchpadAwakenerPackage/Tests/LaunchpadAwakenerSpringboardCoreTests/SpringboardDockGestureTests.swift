import CoreGraphics
import LaunchpadAwakenerSpringboardCore
import Testing

/// A press on the Dock is followed the way the Dock itself follows it, so the springboard closes after a click
/// on the Dock but stays up after an icon was dragged out of it, as macOS 15's Launchpad did.
@Suite("Gestures that begin on the Dock")
struct SpringboardDockGestureTests {
    private static let pressLocation = CGPoint(x: 700, y: 900)

    @Test("letting go without moving is a click")
    func releaseWithoutMoving() {
        let gesture = SpringboardDockGesture(startLocation: Self.pressLocation)
        #expect(gesture.endsInClick)
    }

    @Test("moving up to the threshold along either axis is still a click", arguments: [
        CGPoint(x: 705, y: 900),
        CGPoint(x: 695, y: 895),
        CGPoint(x: 705, y: 905),
    ])
    func movingWithinThreshold(location: CGPoint) {
        var gesture = SpringboardDockGesture(startLocation: Self.pressLocation)
        gesture.pointerDragged(to: location)
        #expect(gesture.endsInClick)
    }

    @Test("moving past the threshold along either axis is a drag", arguments: [
        CGPoint(x: 705.5, y: 900),
        CGPoint(x: 700, y: 894),
    ])
    func movingPastThreshold(location: CGPoint) {
        var gesture = SpringboardDockGesture(startLocation: Self.pressLocation)
        gesture.pointerDragged(to: location)
        #expect(!gesture.endsInClick)
    }

    @Test("a drag stays one when the pointer comes back to where it was pressed")
    func dragThatComesBack() {
        // The Dock latches its own `_movedEnough` the same way: dragging an icon out and back is not a click.
        var gesture = SpringboardDockGesture(startLocation: Self.pressLocation)
        gesture.pointerDragged(to: CGPoint(x: 700, y: 600))
        gesture.pointerDragged(to: Self.pressLocation)
        #expect(!gesture.endsInClick)
    }
}
