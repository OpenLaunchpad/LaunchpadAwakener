import CoreGraphics
import Foundation
import QuartzCore

/// macOS 15's jiggle mode, which its code calls `deleting`: every icon of the pages shown shakes until
/// the mode ends.
///
/// A press held still on an icon for 1 second, or 5 with Shift, starts it, and another ends it
/// (`-[ECSBEventHandler leftMouseDown:inLayer:ofPage:]`, 15.5 `0x10006E7EC`). Escape ends it after a
/// drag is cancelled and before a folder closes (`-[Springboard performCancel]` `0x1000985E8`), and so
/// does a click on the background, instead of closing Launchpad (`-[Springboard
/// cancelActionWithEvent:sender:]` `0x100094618`). Holding Option starts it too, and letting go ends it
/// (`-[ECSBSpringboard flagsChanged:]` `0x1000F37AC`). 15 also put a close box on applications from the
/// App Store in this mode, to delete them; the replica leaves deleting out.
enum SpringboardJiggle {
    /// How long a press must be held to start or end the mode.
    static func longPressDuration(isShiftDown: Bool) -> Duration {
        isShiftDown ? .seconds(5) : .seconds(1)
    }

    /// One shake there and back.
    static let cycleDuration: CFTimeInterval = 0.25
    /// 15 stepped the shake 20 times a second rather than following the display, which makes it jerky.
    static let frameInterval: CFTimeInterval = 0.05
    /// How far an icon turns either way, about 2°.
    static let rotationAngle: CGFloat = 0.03525565085
    static let positionAnimationKey = "jigglePosition"
    static let rotationAnimationKey = "jiggleRotation"

    /// 15's two endless, additive shakes of an icon's jitter layer (`sub_1000E8418`, `sub_1000E877C`): a
    /// turn of `rotationAngle` one way and back the other, and a wander between four points, each
    /// coordinate 0 or −1 point, back to the first. Each starts at a phase of its own, a multiple of
    /// `frameInterval`, so that no two icons shake alike.
    static func makeAnimations<Generator: RandomNumberGenerator>(using generator: inout Generator) -> (position: CAKeyframeAnimation, rotation: CAKeyframeAnimation) {
        let positionAnimation = CAKeyframeAnimation(keyPath: "position")
        let firstPoint = randomPoint(using: &generator)
        positionAnimation.values = [firstPoint, randomPoint(using: &generator), randomPoint(using: &generator), randomPoint(using: &generator), firstPoint]

        let rotationAnimation = CAKeyframeAnimation(keyPath: "transform")
        rotationAnimation.valueFunction = CAValueFunction(name: .rotateZ)
        rotationAnimation.values = [-rotationAngle, rotationAngle, -rotationAngle]

        for animation in [positionAnimation, rotationAnimation] {
            animation.duration = cycleDuration
            animation.isAdditive = true
            animation.repeatCount = .greatestFiniteMagnitude
            animation.isRemovedOnCompletion = false
            // A time long past, not one relative to now: the shake is already under way, at a phase of
            // its own.
            animation.beginTime = randomPhase(using: &generator)
            if animation.responds(to: NSSelectorFromString("setFrameInterval:")) {
                animation.setValue(frameInterval, forKey: "frameInterval")
            }
        }
        return (positionAnimation, rotationAnimation)
    }

    /// 15's `floorf(((r + r) * 0.25) − 0.25)` of a random `r` in [0, 1), per coordinate: 0 or −1.
    private static func randomPoint<Generator: RandomNumberGenerator>(using generator: inout Generator) -> NSValue {
        func coordinate() -> CGFloat {
            let fraction = Float(UInt32.random(in: 0...UInt32.max, using: &generator) % 1000) / 1000
            return CGFloat(((fraction + fraction) * 0.25 - 0.25).rounded(.down))
        }
        return NSValue(point: CGPoint(x: coordinate(), y: coordinate()))
    }

    /// 15's `ceilf((r % 1000 + 1) * 0.2) * 0.05`: 0.05 to 10 seconds, in steps of 0.05.
    private static func randomPhase<Generator: RandomNumberGenerator>(using generator: inout Generator) -> CFTimeInterval {
        CFTimeInterval((Float(UInt32.random(in: 0...UInt32.max, using: &generator) % 1000 + 1) * 0.2).rounded(.up)) * 0.05
    }
}

/// Holding Option jiggles the icons, and letting go stops them if Option was held
/// (`-[ECSBSpringboard flagsChanged:]`, 15.5 `0x1000F37AC`).
struct SpringboardOptionKeyJiggle {
    /// Whether Option has gone down since it last came up.
    private(set) var isOptionHeld = false

    /// Whether the icons should jiggle after the modifier keys changed, given whether they do now.
    mutating func isJiggling(afterOptionIsDown isOptionDown: Bool, isJiggling: Bool) -> Bool {
        if isOptionDown {
            isOptionHeld = true
            return true
        }
        guard isOptionHeld else { return isJiggling }
        isOptionHeld = false
        return false
    }
}
