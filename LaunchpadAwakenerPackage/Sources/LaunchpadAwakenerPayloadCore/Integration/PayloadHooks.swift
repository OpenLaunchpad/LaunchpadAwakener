import CoreGraphics
import Foundation
import ObjCRuntimeToolbox
import OSToolbox
import LaunchpadAwakenerSpringboardCore

/// Declares every method this payload replaces in the host process.
///
/// This is the file you edit. Everything else in the payload is plumbing.
///
/// ## Adding a hook
///
/// 1. Find the target method in the host. A decompiler gives you the class and selector; it does
///    *not* reliably give you the types.
/// 2. Read the real type encoding from the live host — attach a throwaway payload, or the debugger:
///
///    ```swift
///    RuntimeMethodInspector.typeEncoding(forClassNamed: "SomeClass", selector: NSSelectorFromString("someMethod:"))
///    ```
///
/// 3. Write the replacement as a method of a `@RuntimeClassHook("SomeClass")` struct, tagged with
///    `@RuntimeMethodReplacement`, whose Swift parameter and return types encode to what you read:
///    `I` is `UInt32`, `f` is `Float`, `B` is `Bool`, `@` an object. The macro derives the selector and
///    the encoding from that one declaration, and installation compares the encoding with the live
///    method, so a wrong type refuses the whole batch instead of corrupting registers at call time.
///    `host` is the receiver; `callOriginal(…)` forwards to the Dock's own implementation.
/// 4. Add the container's `descriptors()` to ``descriptors()`` below — or to ``optionalDescriptors()``
///    when the springboard can do without what it does — and its expected encoding to
///    `PayloadHookSignatureTests`, which checks it against the value read from the Dock.
///
/// A method in the alloc, copy, mutableCopy, new or init family that returns an object cannot be
/// replaced this way — the macro rejects it at compile time.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "PayloadHooks")
public enum PayloadHooks {
    /// The hooks to install, validated and applied as one atomic batch.
    ///
    /// Returning an empty array is a valid state: the payload attaches, logs, and changes nothing. That
    /// is what happens on a Dock whose methods no longer match what this payload recorded for them —
    /// every entry then keeps opening the system's Apps.
    ///
    /// Reaching the Dock's globals is deliberately not a condition here. They are found on first use
    /// rather than now, because the payload can arrive within 250 ms of the Dock starting, before it has
    /// built its singletons; and without them the replica still opens, it just stops sitting flush
    /// against the Dock. What the app shows about them comes from ``DockBarReference/reachability``,
    /// asked afresh each time the control panel refreshes.
    public static func descriptors() -> [RuntimeMethodHook.Descriptor] {
        guard DockHostInterface.isCompatible else {
            #log(.error, "The Dock's methods do not match this payload; installing no hooks")
            return []
        }
        return springboardDescriptors()
    }

    /// The hooks the springboard cannot work without: every way into it, and every event it takes.
    static func springboardDescriptors() -> [RuntimeMethodHook.Descriptor] {
        SpotlightHooks.descriptors() + DockAppEventHandlerHooks.descriptors()
    }

    /// The hooks the springboard can do without, installed as a batch of their own once ``descriptors()`` is
    /// in: a Dock whose method no longer matches loses only what the hook does, not the springboard. Keeping
    /// the Dock on its display while the springboard shows is one; without it the Dock moves as 26 and 27 let it.
    public static func optionalDescriptors() -> [RuntimeMethodHook.Descriptor] {
        DockVisibilityHooks.descriptors()
    }
}

/// On macOS 27.2 every path that opens Apps — the Launchpad key, the pinch gesture, the Apps
/// application — ends in `-[Spotlight sendLaunchAppsBrowsing]`, so replacing it takes them all over at
/// once.
@RuntimeClassHook("Spotlight")
struct SpotlightHooks {
    @RuntimeMethodReplacement
    func sendLaunchAppsBrowsing() {
        guard !SpringboardController.isDisabledByKillSwitch else {
            callOriginal()
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                SpringboardController.shared.toggle(reason: "launch apps browsing")
            }
        }
    }
}

/// On macOS 27.2 every event the Dock receives passes through
/// `-[DockAppEventHandler handleDockBarEvent:type:]`, from `-[DockAppEventHandler handleMachMessage:size:]`
/// — the same funnel where macOS 15 offered each event to Launchpad before the Dock bar. While the
/// springboard is hidden this only forwards.
@RuntimeClassHook("DockAppEventHandler")
struct DockAppEventHandlerHooks {
    /// `eventObject` is the event's `CGEvent`, typed as an object because that is how the Dock declares it.
    @RuntimeMethodReplacement
    func handleDockBarEvent(_ eventObject: AnyObject?, type eventType: UInt32) {
        if let eventObject, Thread.isMainThread {
            let event = unsafeDowncast(eventObject, to: CGEvent.self)
            let inputEvent = SpringboardInputEvent(event: event, eventType: eventType)
            SpringboardCurrentEvent.event = event
            let isConsumed = MainActor.assumeIsolated {
                SpringboardController.shared.handle(inputEvent)
            }
            SpringboardCurrentEvent.event = nil
            if isConsumed { return }
        }
        callOriginal(eventObject, eventType)
    }
}

/// The pointer at another display's bottom edge moves the Dock there through
/// `-[DockVisibility forceDockOntoDisplay:]`, which macOS 15's Dock left at once while Launchpad showed. 26 and
/// 27 check only for an open stack, so the springboard keeps the Dock on its display itself; otherwise the
/// Dock moves as usual, and the icons are rendered for where it goes.
@RuntimeClassHook("DockVisibility")
struct DockVisibilityHooks {
    /// `displayIdentifier` is the `CGDirectDisplayID` the Dock is asked to move to.
    @RuntimeMethodReplacement
    func forceDockOntoDisplay(_ displayIdentifier: UInt32) {
        // The Dock asks from its event handling, on the main thread; anything else is left to the Dock.
        guard Thread.isMainThread else {
            callOriginal(displayIdentifier)
            return
        }
        let allowsMove = MainActor.assumeIsolated {
            SpringboardController.shared.allowsDockToChangeDisplay(to: displayIdentifier)
        }
        guard allowsMove else { return }
        callOriginal(displayIdentifier)
        MainActor.assumeIsolated {
            SpringboardController.shared.dockWillChangeDisplay(to: displayIdentifier)
        }
    }
}
