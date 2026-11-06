import CoreGraphics
@testable import LaunchpadAwakenerPayloadCore
import QuartzCore
import Testing

/// macOS 15.5's jiggle mode. Expected values are the constants of `sub_1000E8418` and `sub_1000E877C`
/// (the two shakes), `-[ECSBEventHandler leftMouseDown:inLayer:ofPage:]` (the long press) and
/// `-[ECSBSpringboard flagsChanged:]` (Option).
@Suite("Jiggle mode")
@MainActor
struct SpringboardJiggleTests {
    /// SplitMix64, so that every run draws the same numbers.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    @Test("an icon turns about 2° one way and back the other, four times a second, without end")
    func rotation() throws {
        var generator = SeededGenerator(state: 1)
        let rotation = SpringboardJiggle.makeAnimations(using: &generator).rotation

        #expect(rotation.keyPath == "transform")
        #expect(rotation.valueFunction?.name == .rotateZ)
        let angles = try #require(rotation.values as? [CGFloat])
        #expect(angles == [-0.03525565085, 0.03525565085, -0.03525565085])
        #expect(rotation.duration == 0.25)
        #expect(rotation.isAdditive)
        #expect(rotation.repeatCount == .greatestFiniteMagnitude)
        #expect(!rotation.isRemovedOnCompletion)
    }

    @Test("an icon wanders between four points a point apart at most, and back to the first", arguments: [1, 2, 3, 42, 2026] as [UInt64])
    func wander(seed: UInt64) throws {
        var generator = SeededGenerator(state: seed)
        let position = SpringboardJiggle.makeAnimations(using: &generator).position

        #expect(position.keyPath == "position")
        let points = try #require(position.values as? [NSValue]).map(\.pointValue)
        #expect(points.count == 5)
        #expect(points.first == points.last)
        for point in points {
            #expect([0, -1].contains(point.x))
            #expect([0, -1].contains(point.y))
        }
        #expect(position.duration == 0.25)
        #expect(position.isAdditive)
    }

    @Test("each shake starts at a phase of its own, a multiple of 0.05 s from 0.05 to 10 s", arguments: [1, 7, 99] as [UInt64])
    func phase(seed: UInt64) {
        var generator = SeededGenerator(state: seed)
        let animations = SpringboardJiggle.makeAnimations(using: &generator)

        for beginTime in [animations.position.beginTime, animations.rotation.beginTime] {
            #expect(beginTime >= 0.05 && beginTime <= 10)
            let steps = beginTime / 0.05
            #expect(abs(steps - steps.rounded()) < 0.0001)
        }
    }

    @Test("the shake moves in steps, 20 a second")
    func steps() {
        var generator = SeededGenerator(state: 5)
        let animations = SpringboardJiggle.makeAnimations(using: &generator)

        for animation in [animations.position, animations.rotation] {
            #expect(animation.value(forKey: "frameInterval") as? Double == 0.05)
        }
    }

    @Test("a press switches jiggle mode after 1 second, or 5 with Shift")
    func longPress() {
        #expect(SpringboardJiggle.longPressDuration(isShiftDown: false) == .seconds(1))
        #expect(SpringboardJiggle.longPressDuration(isShiftDown: true) == .seconds(5))
    }

    @Test("holding Option jiggles the icons and letting it go stops them")
    func optionKey() {
        var optionKeyJiggle = SpringboardOptionKeyJiggle()

        let afterOptionDown = optionKeyJiggle.isJiggling(afterOptionIsDown: true, isJiggling: false)
        // Shift going down with Option still held changes nothing.
        let afterShiftDown = optionKeyJiggle.isJiggling(afterOptionIsDown: true, isJiggling: true)
        let afterOptionUp = optionKeyJiggle.isJiggling(afterOptionIsDown: false, isJiggling: true)

        #expect(afterOptionDown)
        #expect(afterShiftDown)
        #expect(!afterOptionUp)
    }

    @Test("Option let go ends jiggle mode even when a long press started it, as in 15")
    func optionKeyAfterLongPress() {
        var optionKeyJiggle = SpringboardOptionKeyJiggle()

        let afterOptionDown = optionKeyJiggle.isJiggling(afterOptionIsDown: true, isJiggling: true)
        let afterOptionUp = optionKeyJiggle.isJiggling(afterOptionIsDown: false, isJiggling: true)

        #expect(afterOptionDown)
        #expect(!afterOptionUp)
    }

    @Test("other modifier keys leave jiggle mode as it is")
    func otherModifierKeys() {
        var optionKeyJiggle = SpringboardOptionKeyJiggle()

        let whileJiggling = optionKeyJiggle.isJiggling(afterOptionIsDown: false, isJiggling: true)
        let whileStill = optionKeyJiggle.isJiggling(afterOptionIsDown: false, isJiggling: false)

        #expect(whileJiggling)
        #expect(!whileStill)
    }

    @Test("an icon shakes in jiggle mode unless it is held still")
    func itemShakes() {
        let itemLayer = SpringboardItemLayer()
        func isShaking() -> Bool {
            itemLayer.jitterLayer.animation(forKey: SpringboardJiggle.rotationAnimationKey) != nil
                && itemLayer.jitterLayer.animation(forKey: SpringboardJiggle.positionAnimationKey) != nil
        }

        #expect(!isShaking())
        itemLayer.isJiggling = true
        #expect(isShaking())
        itemLayer.isHeldStill = true
        #expect(!isShaking())
        itemLayer.isHeldStill = false
        #expect(isShaking())
        itemLayer.isJiggling = false
        #expect(!isShaking())
    }
}
