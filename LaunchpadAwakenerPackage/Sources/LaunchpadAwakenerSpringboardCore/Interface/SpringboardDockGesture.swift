import CoreGraphics

/// A left-button press on the Dock while the springboard shows, followed until the button comes up.
///
/// Every event of such a gesture is the Dock's, wherever the pointer goes: the Dock decides on the drag
/// events whether the press becomes a drag of the icon under it, and on the release whether it was a click.
/// macOS 15's Launchpad left the Dock usable in the same way — an icon could be dragged out of the Dock and
/// removed while Launchpad showed — and closed Launchpad only from the icon's click action
/// (15.5 `0x10002CE10`), never after a drag.
///
/// The Dock's own rule, which this mirrors so the springboard knows which of the two the release ends
/// (`-[DockBarMouseEventHandler _handleTileClickEvent:type:]`, 27.2 `0x1000837CC`, 26.6.2 `0x1001129A4`):
/// the press becomes a drag once a drag event lands more than ``dragThreshold`` points from where the button
/// went down along either axis, and stays one from then on.
package struct SpringboardDockGesture: Equatable, Sendable {
    /// How far the pointer may move from the press, along either axis, before the Dock drags the icon.
    package static let dragThreshold: CGFloat = 5

    /// Where the button went down, in global coordinates.
    package let startLocation: CGPoint
    /// Whether the press has turned into a drag; it never turns back.
    private var hasBecomeDrag = false

    package init(startLocation: CGPoint) {
        self.startLocation = startLocation
    }

    /// Takes a drag event of the gesture.
    package mutating func pointerDragged(to location: CGPoint) {
        guard !hasBecomeDrag else { return }
        let distance = max(abs(location.x - startLocation.x), abs(location.y - startLocation.y))
        hasBecomeDrag = distance > Self.dragThreshold
    }

    /// Whether letting go now is a click on the Dock, which opens whatever it was on, rather than the end of
    /// a drag.
    package var endsInClick: Bool {
        !hasBecomeDrag
    }
}

/// Sorts the springboard's left-button events into the Dock's and its own, one gesture at a time.
///
/// A press on the Dock starts a ``SpringboardDockGesture``, and every event up to the release is the Dock's. A
/// press anywhere else is the springboard's, with its drags and its release, and ends any gesture on the Dock
/// whose release went unseen.
package struct SpringboardDockGestureTracker: Sendable {
    /// What the release of a left-button gesture means to the springboard.
    package enum Release: Equatable, Sendable {
        /// The gesture began off the Dock: the springboard handles the release itself.
        case springboard
        /// The Dock takes the release as a click and opens what was clicked, so the springboard closes.
        case dockClick
        /// The Dock takes the release as the end of a drag, so the springboard stays.
        case dockDrag
    }

    private var gesture: SpringboardDockGesture?

    package init() {}

    /// Whether a gesture that began on the Dock is going on: the Dock's handling of any of its drag events may
    /// start, or carry on, a drag of one of the Dock's icons.
    package var isDockGestureInProgress: Bool {
        gesture != nil
    }

    /// A left press. Returns whether it is the Dock's.
    package mutating func press(at location: CGPoint, isOnDock: Bool) -> Bool {
        gesture = isOnDock ? SpringboardDockGesture(startLocation: location) : nil
        return isOnDock
    }

    /// A left drag event. Returns whether it is the Dock's.
    package mutating func drag(to location: CGPoint) -> Bool {
        guard gesture != nil else { return false }
        gesture?.pointerDragged(to: location)
        return true
    }

    /// The left button coming up, which ends the gesture.
    package mutating func release() -> Release {
        defer { gesture = nil }
        guard let gesture else { return .springboard }
        return gesture.endsInClick ? .dockClick : .dockDrag
    }

    /// Forgets a gesture whose release went unseen, as one that ended while the springboard was hidden.
    package mutating func reset() {
        gesture = nil
    }
}
