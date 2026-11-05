import CoreGraphics
import Foundation
import ObjectiveC
import OSLog
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
public enum PayloadHooks {
    private static let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakener", category: "PayloadHooks")

    /// The hooks to install, validated and applied as one atomic batch.
    ///
    /// Returning an empty array is a valid state: the payload attaches, logs, and changes nothing.
    /// That is the right first milestone for a new project — prove injection works before changing
    /// any behaviour.
    public static func descriptors() -> [MethodHookDescriptor] {
        // The overlay calls into the Dock's window class; if that no longer matches, taking over
        // the Launchpad key would leave it doing nothing, so install no hook at all.
        guard DockHostInterface.isCompatible else {
            logger.error("The Dock's window interface does not match this payload; installing no hooks")
            return []
        }
        return [launchAppsBrowsingHook, dockBarEventHook, dockBarRectHook, dockBarRollTileHook]
    }

    private static let dockBarRollTileSelectorName = "setRollTile:"

    /// Only observes, like `dockBarRectHook`. The Dock calls this whenever the pointer moves onto a
    /// different tile, so the `DockBar` is known before any click on it — `rect` alone is called too
    /// rarely on macOS 27.2 to be relied on.
    private static var dockBarRollTileHook: MethodHookDescriptor {
        MethodHookDescriptor(
            className: "DockBar",
            selector: NSSelectorFromString(dockBarRollTileSelectorName),
            expectedTypeEncoding: "v24@0:8@16",
            makeReplacement: { originalImplementation in
                typealias OriginalFunction = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                let callOriginal = unsafeBitCast(originalImplementation, to: OriginalFunction.self)
                let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { receiver, rollTile in
                    callOriginal(receiver, NSSelectorFromString(dockBarRollTileSelectorName), rollTile)
                    if Thread.isMainThread {
                        // Already on the main thread, where the Dock owns its `DockBar`; nothing crosses threads.
                        nonisolated(unsafe) let dockBar = receiver
                        MainActor.assumeIsolated {
                            DockBarReference.remember(dockBar: dockBar)
                        }
                    }
                }
                return imp_implementationWithBlock(replacement)
            }
        )
    }

    private static let dockBarRectSelectorName = "rect"

    /// Only observes: remembers the Dock's `DockBar`, which nothing exported leads to, so the overlay
    /// can ask for the bar's rectangle the way macOS 15's `-[DockAppEventHandler
    /// handleSpringboardEvent:type:]` did to let clicks on the Dock through.
    private static var dockBarRectHook: MethodHookDescriptor {
        MethodHookDescriptor(
            className: "DockBar",
            selector: NSSelectorFromString(dockBarRectSelectorName),
            expectedTypeEncoding: "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8",
            makeReplacement: { originalImplementation in
                typealias OriginalFunction = @convention(c) (AnyObject, Selector) -> CGRect
                let callOriginal = unsafeBitCast(originalImplementation, to: OriginalFunction.self)
                let replacement: @convention(block) (AnyObject) -> CGRect = { receiver in
                    let barRect = callOriginal(receiver, NSSelectorFromString(dockBarRectSelectorName))
                    if Thread.isMainThread {
                        // Already on the main thread, where the Dock owns its `DockBar`; nothing crosses threads.
                        nonisolated(unsafe) let dockBar = receiver
                        MainActor.assumeIsolated {
                            DockBarReference.remember(dockBar: dockBar)
                        }
                    }
                    return barRect
                }
                return imp_implementationWithBlock(replacement)
            }
        )
    }

    private static let dockBarEventSelectorName = "handleDockBarEvent:type:"

    /// On macOS 27.2 every event the Dock receives passes through here, from
    /// `-[DockAppEventHandler handleMachMessage:size:]` — the same funnel where macOS 15 offered each
    /// event to Launchpad before the Dock bar. While the overlay is hidden this only forwards.
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
                        let inputEvent = OverlayInputEvent(event: unsafeBitCast(eventObject, to: CGEvent.self), eventType: eventType)
                        let isConsumed = MainActor.assumeIsolated {
                            LaunchpadPrototypeOverlay.shared.handle(inputEvent)
                        }
                        if isConsumed { return }
                    }
                    callOriginal(receiver, NSSelectorFromString(dockBarEventSelectorName), eventObject, eventType)
                }
                return imp_implementationWithBlock(replacement)
            }
        )
    }

    private static let launchAppsBrowsingSelectorName = "sendLaunchAppsBrowsing"

    /// On macOS 27.2 every path that opens Apps — the Launchpad key among them — ends in this one
    /// method, so replacing it takes them all over at once.
    private static var launchAppsBrowsingHook: MethodHookDescriptor {
        MethodHookDescriptor(
            className: "Spotlight",
            selector: NSSelectorFromString(launchAppsBrowsingSelectorName),
            expectedTypeEncoding: "v16@0:8",
            makeReplacement: { originalImplementation in
                typealias OriginalFunction = @convention(c) (AnyObject, Selector) -> Void
                let callOriginal = unsafeBitCast(originalImplementation, to: OriginalFunction.self)
                let replacement: @convention(block) (AnyObject) -> Void = { receiver in
                    guard !LaunchpadPrototypeOverlay.isDisabledByKillSwitch else {
                        callOriginal(receiver, NSSelectorFromString(launchAppsBrowsingSelectorName))
                        return
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            LaunchpadPrototypeOverlay.shared.toggle()
                        }
                    }
                }
                return imp_implementationWithBlock(replacement)
            }
        )
    }
}
