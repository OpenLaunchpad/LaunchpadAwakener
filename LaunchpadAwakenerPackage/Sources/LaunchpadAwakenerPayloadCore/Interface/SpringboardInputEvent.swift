import CoreGraphics

/// One event the Dock received, reduced to what the springboard needs.
///
/// `CGEvent` is not `Sendable`, so the event hook copies these fields out on the event's own thread
/// before anything reaches the main actor.
struct SpringboardInputEvent: Sendable {
    enum MouseButton: Sendable, Equatable {
        case left
        case right
        case other
    }

    struct ScrollWheel: Sendable, Equatable {
        /// Point deltas as the system delivers them, natural scrolling already applied.
        let horizontalDelta: Double
        let verticalDelta: Double
        /// True for trackpads and other pixel-precise devices, false for notched wheels.
        let isContinuous: Bool
        /// `kCGScrollPhase*`; zero for wheels and momentum events.
        let scrollPhase: Int64
        /// `kCGMomentumScrollPhase*`; zero outside momentum.
        let momentumPhase: Int64
    }

    enum Kind: Sendable, Equatable {
        case keyDown(keyCode: Int64, characters: String, isRepeat: Bool)
        case keyUp(keyCode: Int64)
        case modifiersChanged
        case mouseDown(MouseButton, clickCount: Int64)
        case mouseUp(MouseButton)
        case mouseDragged(MouseButton)
        case mouseMoved
        case scrollWheel(ScrollWheel)
        /// Gestures, system-defined keys and everything else.
        case other(eventType: UInt32)
    }

    let kind: Kind
    /// Global coordinates with a top-left origin, the space of `-[DockBar rect]`.
    let location: CGPoint
    let modifierFlags: CGEventFlags

    var hasCommandModifier: Bool {
        modifierFlags.contains(.maskCommand)
    }
}

/// Virtual key codes the springboard reacts to (`kVK_*` in Carbon's `Events.h`).
enum SpringboardKeyCode {
    static let returnKey: Int64 = 36
    static let tab: Int64 = 48
    static let delete: Int64 = 51
    static let escape: Int64 = 53
    static let keypadEnter: Int64 = 76
    static let leftArrow: Int64 = 123
    static let rightArrow: Int64 = 124
    static let downArrow: Int64 = 125
    static let upArrow: Int64 = 126
}
