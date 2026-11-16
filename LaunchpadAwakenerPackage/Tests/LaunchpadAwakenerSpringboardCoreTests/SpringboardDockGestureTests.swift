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

/// Which left-button events the springboard leaves to the Dock, and whether it closes on the release: a press on
/// the Dock hands the whole gesture over, wherever the pointer goes, and only a click closes the springboard.
@Suite("Sorting left-button events between the Dock and the springboard")
struct SpringboardDockGestureTrackerTests {
    private static let dockLocation = CGPoint(x: 700, y: 900)
    private static let springboardLocation = CGPoint(x: 700, y: 400)

    @Test("a press on the Dock and every event after it are the Dock's, even off the Dock")
    func dockGestureGoesToDock() {
        var tracker = SpringboardDockGestureTracker()
        let isPressForDock = tracker.press(at: Self.dockLocation, isOnDock: true)
        #expect(isPressForDock)
        #expect(tracker.isDockGestureInProgress)
        let isDragOverDockForDock = tracker.drag(to: CGPoint(x: 700, y: 880))
        let isDragOverSpringboardForDock = tracker.drag(to: Self.springboardLocation)
        #expect(isDragOverDockForDock)
        #expect(isDragOverSpringboardForDock)
        let release = tracker.release()
        #expect(release == .dockDrag)
        #expect(!tracker.isDockGestureInProgress)
    }

    @Test("a press on the Dock let go within the threshold is a click, which closes the springboard")
    func dockClick() {
        var tracker = SpringboardDockGestureTracker()
        _ = tracker.press(at: Self.dockLocation, isOnDock: true)
        let isDragForDock = tracker.drag(to: CGPoint(x: 702, y: 899))
        #expect(isDragForDock)
        let release = tracker.release()
        #expect(release == .dockClick)
    }

    @Test("a press off the Dock, its drags and its release are the springboard's, even over the Dock")
    func springboardGesture() {
        var tracker = SpringboardDockGestureTracker()
        let isPressForDock = tracker.press(at: Self.springboardLocation, isOnDock: false)
        #expect(!isPressForDock)
        #expect(!tracker.isDockGestureInProgress)
        let isDragForDock = tracker.drag(to: Self.dockLocation)
        #expect(!isDragForDock)
        let release = tracker.release()
        #expect(release == .springboard)
    }

    @Test("a press off the Dock ends a gesture on the Dock whose release went unseen")
    func pressEndsUnseenGesture() {
        // The Dock's drag of an icon follows the pointer itself; its release need not come back to the springboard.
        var tracker = SpringboardDockGestureTracker()
        _ = tracker.press(at: Self.dockLocation, isOnDock: true)
        _ = tracker.drag(to: Self.springboardLocation)
        let isNextPressForDock = tracker.press(at: Self.springboardLocation, isOnDock: false)
        #expect(!isNextPressForDock)
        let isNextDragForDock = tracker.drag(to: CGPoint(x: 720, y: 400))
        #expect(!isNextDragForDock)
        let release = tracker.release()
        #expect(release == .springboard)
    }

    @Test("after the release, drags without a new press are the springboard's")
    func releaseEndsGesture() {
        var tracker = SpringboardDockGestureTracker()
        _ = tracker.press(at: Self.dockLocation, isOnDock: true)
        _ = tracker.release()
        let isLaterDragForDock = tracker.drag(to: Self.springboardLocation)
        #expect(!isLaterDragForDock)
    }

    @Test("a reset forgets the gesture")
    func reset() {
        var tracker = SpringboardDockGestureTracker()
        _ = tracker.press(at: Self.dockLocation, isOnDock: true)
        tracker.reset()
        #expect(!tracker.isDockGestureInProgress)
        let release = tracker.release()
        #expect(release == .springboard)
    }
}
