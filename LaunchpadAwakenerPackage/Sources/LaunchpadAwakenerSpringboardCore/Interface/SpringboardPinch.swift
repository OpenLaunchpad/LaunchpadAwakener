import CoreGraphics
import Foundation

/// macOS 15.5's pinch to open and spread to close: the raw DockSwipe fields turned into a visibility
/// between 0 and 1, and the spring that finishes the gesture (`-[LPSpringboard fluidGestureProgress:]`,
/// 15.5 `0x1000B1764`; `_animateFluidToDone:`, `0x1000B1EDC`).
package enum SpringboardPinch {
    /// Pinching in (the thumb and three fingers closing) opens; spreading closes. Decided on the first
    /// event and kept for the whole gesture (`DOCKGestures_gestureForDockSwipeEvent`, `0x1000AED7C`).
    package static func isPinchingIn(rawProgress: Double, directionFlag: Bool) -> Bool {
        directionFlag ? rawProgress > 0 : rawProgress <= 0
    }

    /// The progress along the gesture's own direction (`-[DOCKGestureEvent intendedProgress]`).
    package static func intendedProgress(rawProgress: Double, directionFlag: Bool) -> Double {
        directionFlag ? rawProgress : -rawProgress
    }

    /// How visible the springboard is at `intendedProgress`: opening goes 0 → 1 with the progress,
    /// closing starts from 1 as the progress goes 0 → −1.
    package static func visibility(forIntendedProgress intendedProgress: Double, isOpening: Bool) -> Double {
        let visibility = isOpening ? intendedProgress : intendedProgress + 1
        return min(max(visibility, 0), 1)
    }

    /// Whether a gesture that ended at `intendedProgress` completes. 15 had no threshold: an end flagged
    /// as cancelled, or progress back past the start, undoes it; anything else completes.
    package static func completes(isCancelled: Bool, intendedProgress: Double, isOpening: Bool) -> Bool {
        guard !isCancelled else { return false }
        return isOpening ? intendedProgress >= 0 : intendedProgress <= 0
    }

    /// The opacity and grid scale 15 set for a visibility (`-[LPSpringboard _animateToVisibility:]`,
    /// `0x1000B209C`): the scale is not clamped, so overshoot shrinks the grid below 1.
    package static func gridScale(forVisibility visibility: Double) -> CGFloat {
        CGFloat(1.0499999523 - 0.0499999523 * visibility)
    }
}

/// The spring that carries a released pinch to fully shown or fully hidden, stepped at 60 Hz.
///
/// Without overshoot, as in 15 (`_allowBounce` was never set): it stops where it would cross the target.
/// It settles with a time constant of about 0.15 s.
package struct SpringboardVisibilitySpring: Sendable, Equatable {
    package static let framesPerSecond: Double = 60

    package private(set) var visibility: Double
    package private(set) var velocity: Double
    package let target: Double
    private let startVisibility: Double
    package private(set) var isFinished = false

    package init(visibility: Double, velocity: Double, target: Double) {
        self.visibility = visibility
        // 15 damped the initial velocity when the gesture had already gone past either end.
        self.velocity = visibility <= 0 || visibility > 1 ? velocity * 0.25 : velocity
        self.target = target
        startVisibility = visibility
    }

    /// Advances one 60 Hz frame.
    package mutating func step() {
        guard !isFinished else { return }
        velocity = velocity * 0.695 + (target - visibility) * 2.0
        visibility += velocity / Self.framesPerSecond

        let hasCrossedTarget = startVisibility <= target ? visibility >= target : visibility <= target
        if hasCrossedTarget {
            finish()
            return
        }
        if visibility < 0 {
            velocity = velocity * 0.85 + (0 - visibility) * 0.8
            if abs(velocity) < 0.01, -visibility < 0.00001 {
                finish()
            }
        } else if visibility > 1 {
            velocity = velocity * 0.85 + (visibility - 1) * -0.8
            if abs(velocity) < 0.01, visibility - 1 < 0.00001 {
                finish()
            }
        } else if abs(velocity) < 0.01, abs(visibility - target) < 0.00001 {
            finish()
        }
    }

    private mutating func finish() {
        visibility = target
        velocity = 0
        isFinished = true
    }
}
