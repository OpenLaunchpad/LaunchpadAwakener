import CoreGraphics
import Foundation
import ObjectiveC
import OSToolbox
import LaunchpadAwakenerHookKit

/// Declares every method this payload replaces in the host process.
///
/// This is the file you edit. Everything else in the payload is plumbing.
///
/// ## Adding a hook
///
/// 1. Find the target method in the host. A decompiler gives you the class and selector; it does
///    *not* reliably give you the type encoding.
/// 2. Get the real type encoding by running against the live host. Attach a throwaway payload — or
///    the debugger — and read it:
///
///    ```swift
///    MethodHookInspector.typeEncoding(forClassNamed: "SomeClass", selector: NSSelectorFromString("someMethod:"))
///    ```
///
///    Never hand-write the encoding. A wrong one that happens to have the right length passes the
///    check and then corrupts registers at call time.
/// 3. Add a descriptor below. Build the replacement with `imp_implementationWithBlock`; the block's
///    first parameter is the receiver and the selector is *not* passed.
/// 4. Cast `originalImplementation` to a `@convention(c)` function type whose parameter list matches
///    the encoding — receiver, then selector, then the method's own arguments — and call it to get
///    the host's behaviour.
///
/// ## Worked example
///
/// Replacing `-[NSView setHidden:]` so the host can never hide a particular view:
///
/// ```swift
/// MethodHookDescriptor(
///     className: "NSView",
///     selector: #selector(setter: NSView.isHidden),
///     expectedTypeEncoding: "v20@0:8B16",
///     makeReplacement: { originalImplementation in
///         typealias OriginalFunction = @convention(c) (AnyObject, Selector, Bool) -> Void
///         let callOriginal = unsafeBitCast(originalImplementation, to: OriginalFunction.self)
///         let replacement: @convention(block) (AnyObject, Bool) -> Void = { receiver, isHidden in
///             // Forward everything except the case this payload exists to change.
///             callOriginal(receiver, #selector(setter: NSView.isHidden), isHidden)
///         }
///         return imp_implementationWithBlock(replacement)
///     }
/// )
/// ```
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "PayloadHooks")
public enum PayloadHooks {
    /// The hooks to install, validated and applied as one atomic batch.
    ///
    /// Returning an empty array is a valid state: the payload attaches, logs, and changes nothing. That
    /// is what happens on a Dock build this payload does not know, or whose methods no longer match —
    /// every entry then keeps opening the system's Apps.
    public static func descriptors() -> [MethodHookDescriptor] {
        guard DockBuildProfile.current != nil else {
            #log(.error, "Unknown Dock build; installing no hooks")
            return []
        }
        guard DockHostInterface.isCompatible else {
            #log(.error, "The Dock's methods do not match this payload; installing no hooks")
            return []
        }
        return [launchAppsBrowsingHook, dockBarEventHook]
    }

    private static let dockBarEventSelectorName = "handleDockBarEvent:type:"

    /// On macOS 27.2 every event the Dock receives passes through here, from
    /// `-[DockAppEventHandler handleMachMessage:size:]` — the same funnel where macOS 15 offered each
    /// event to Launchpad before the Dock bar. While the springboard is hidden this only forwards.
    private static var dockBarEventHook: MethodHookDescriptor {
        MethodHookDescriptor(
            className: "DockAppEventHandler",
            selector: NSSelectorFromString(dockBarEventSelectorName),
            expectedTypeEncoding: "v24@0:8@16I20",
            makeReplacement: { originalImplementation in
                typealias OriginalFunction = @convention(c) (AnyObject, Selector, AnyObject?, UInt32) -> Void
                let callOriginal = unsafeBitCast(originalImplementation, to: OriginalFunction.self)
                let replacement: @convention(block) (AnyObject, AnyObject?, UInt32) -> Void = { receiver, eventObject, eventType in
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
                    callOriginal(receiver, NSSelectorFromString(dockBarEventSelectorName), eventObject, eventType)
                }
                return imp_implementationWithBlock(replacement)
            }
        )
    }

    private static let launchAppsBrowsingSelectorName = "sendLaunchAppsBrowsing"

    /// On macOS 27.2 every path that opens Apps — the Launchpad key, the pinch gesture, the Apps
    /// application — ends in this one method, so replacing it takes them all over at once.
    private static var launchAppsBrowsingHook: MethodHookDescriptor {
        MethodHookDescriptor(
            className: "Spotlight",
            selector: NSSelectorFromString(launchAppsBrowsingSelectorName),
            expectedTypeEncoding: "v16@0:8",
            makeReplacement: { originalImplementation in
                typealias OriginalFunction = @convention(c) (AnyObject, Selector) -> Void
                let callOriginal = unsafeBitCast(originalImplementation, to: OriginalFunction.self)
                let replacement: @convention(block) (AnyObject) -> Void = { receiver in
                    guard !SpringboardController.isDisabledByKillSwitch else {
                        callOriginal(receiver, NSSelectorFromString(launchAppsBrowsingSelectorName))
                        return
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            SpringboardController.shared.toggle(reason: "launch apps browsing")
                        }
                    }
                }
                return imp_implementationWithBlock(replacement)
            }
        )
    }
}
