import CoreGraphics
import LaunchpadAwakenerPayloadCore
import Testing

/// Expected behaviour follows sections 3.2–3.7 of `/Volumes/RE/Dock/27.2/Notes/PinchGesture.md`.
@Suite("Pinching by macOS 15's rules")
struct SpringboardPinchTests {
    @Test("the direction flag decides which sign of progress is pinching in")
    func direction() {
        #expect(SpringboardPinch.isPinchingIn(rawProgress: 0.1, directionFlag: true))
        #expect(!SpringboardPinch.isPinchingIn(rawProgress: 0.1, directionFlag: false))
        #expect(SpringboardPinch.intendedProgress(rawProgress: 0.3, directionFlag: false) == -0.3)
    }

    @Test("opening follows the progress, closing counts down from fully shown")
    func visibility() {
        #expect(SpringboardPinch.visibility(forIntendedProgress: 0.4, isOpening: true) == 0.4)
        #expect(SpringboardPinch.visibility(forIntendedProgress: 1.7, isOpening: true) == 1)
        #expect(SpringboardPinch.visibility(forIntendedProgress: -0.25, isOpening: false) == 0.75)
    }

    @Test("only a cancelled end or one back past the start fails")
    func completion() {
        #expect(SpringboardPinch.completes(isCancelled: false, intendedProgress: 0.05, isOpening: true))
        #expect(!SpringboardPinch.completes(isCancelled: true, intendedProgress: 0.9, isOpening: true))
        #expect(!SpringboardPinch.completes(isCancelled: false, intendedProgress: -0.1, isOpening: true))
        #expect(!SpringboardPinch.completes(isCancelled: false, intendedProgress: 0.1, isOpening: false))
    }

    @Test("the grid is 5 % larger when hidden and full size when shown")
    func gridScale() {
        #expect(abs(SpringboardPinch.gridScale(forVisibility: 0) - 1.05) < 0.0001)
        #expect(abs(SpringboardPinch.gridScale(forVisibility: 1) - 1) < 0.0001)
    }

    /// With a time constant of about 0.15 s, half a second leaves well under 1 % of the way to go; the
    /// spring only declares itself done once the rest is below a hundred-thousandth.
    @Test("a spring released halfway is all but shown after half a second, never overshoots, and ends at 1")
    func springSettlesWithoutOvershoot() {
        var spring = SpringboardVisibilitySpring(visibility: 0.5, velocity: 0, target: 1)
        var largestVisibility = 0.0
        for _ in 0..<30 {
            spring.step()
            largestVisibility = max(largestVisibility, spring.visibility)
        }
        #expect(spring.visibility > 0.995)
        for _ in 0..<150 where !spring.isFinished {
            spring.step()
            largestVisibility = max(largestVisibility, spring.visibility)
        }
        #expect(spring.isFinished)
        #expect(spring.visibility == 1)
        #expect(largestVisibility <= 1)
    }

    @Test("a spring heading back to hidden ends at 0")
    func springBackToHidden() {
        var spring = SpringboardVisibilitySpring(visibility: 0.3, velocity: -0.5, target: 0)
        for _ in 0..<180 where !spring.isFinished {
            spring.step()
        }
        #expect(spring.isFinished)
        #expect(spring.visibility == 0)
    }
}
