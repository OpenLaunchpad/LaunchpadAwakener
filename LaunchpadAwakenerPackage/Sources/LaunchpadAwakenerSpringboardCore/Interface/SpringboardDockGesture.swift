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
    package private(set) var hasBecomeDrag = false

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
