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

    /// Keeping the Dock on its display while the springboard shows: a batch of its own, installed once
    /// ``descriptors()`` is in. A Dock whose method no longer matches loses only this, not the springboard —
    /// the Dock then moves as 26 and 27 let it.
    public static func optionalDescriptors() -> [RuntimeMethodHook.Descriptor] {
        DockVisibilityHooks.descriptors()
    }

    /// The Launchpad icon on the Dock's Apps tile: a batch of its own, for the same reason, and separate
    /// from ``optionalDescriptors()`` so that one of the two failing does not take the other with it.
    ///
    /// Empty when this Dock has neither spelling of its own icon setter; ``DockTileIconHooks`` logs which
    /// ones it tried and what the Dock has instead.
    public static func dockAppsIconDescriptors() -> [RuntimeMethodHook.Descriptor] {
        DockTileIconHooks.descriptors()
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

/// Which spelling of the Dock's own icon path this host uses, and the hook for it.
///
/// ## Why there is more than one spelling
///
/// macOS 26 kept the glass compositing filter on `Tile` as a property, `glassImageCompositingFilter`, shared
/// by the whole tile. macOS 27 deleted the property and made the filter an argument of every icon setter
/// instead, so `setImage:preferredGlassBackgroundStyle:` gained a `glassCompositingFilter:` on the end
/// (26.6.2 and 27.2 Dock metadata; the full account is in the sister project DockIconOverride's
/// "Dock 图标的三条通路").
///
/// ## Why the order is load-bearing
///
/// Both spellings exist on macOS 27, both are still implemented, and both are still called — but not for
/// the same tiles. Cross-referencing the two selector stubs in Dock 2571.1.29: every application-icon path
/// moved to the new spelling (`-[DOCKFileTile render]`, `-[DOCKProcessTile render]`,
/// `-[DockBar _handleLaunchNotification:data:]`), while the nine call sites left on the old one are all
/// stack, trash, folder, URL and window tiles. Hooking the old spelling on macOS 27 therefore installs
/// cleanly, logs success, and never sees an application icon — which is worse than an error, because
/// nothing looks wrong. So the candidate with the filter is tried first.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockTileIconHooks")
enum DockTileIconHooks {
    /// The hook for the spelling this host both declares and matches; empty when it has neither.
    ///
    /// Empty is a deliberate outcome rather than a fallback: better a payload that leaves the Apps tile
    /// alone than one that marshals arguments into a signature the Dock no longer has.
    /// The spellings to try, most recent first. The order is what keeps macOS 27 working — see above.
    static let candidates: [[RuntimeMethodHook.Descriptor]] = [
        DockTileIconHooksWithCompositingFilter.descriptors(),
        DockTileIconHooksWithoutCompositingFilter.descriptors(),
    ]

    static func descriptors() -> [RuntimeMethodHook.Descriptor] {
        guard let matching = candidates.first(where: matchesHost) else {
            for descriptor in candidates.flatMap({ $0 }) {
                let liveTypeEncoding = RuntimeMethodInspector.typeEncoding(
                    forClassNamed: descriptor.className,
                    selector: descriptor.selector,
                    isInstanceMethod: descriptor.isInstanceMethod
                )
                #log(
                    .error,
                    "-[\(descriptor.className, privacy: .public) \(NSStringFromSelector(descriptor.selector), privacy: .public)] expected \(descriptor.expectedTypeEncoding, privacy: .public), found \(liveTypeEncoding ?? "nothing", privacy: .public)"
                )
            }
            return []
        }
        // Default level rather than info: this line is read after a system upgrade, and info does not
        // survive in the log store that long. See ``PayloadEntry``.
        #log(
            .default,
            "The Dock's icon setter on this host: \(matching.map { NSStringFromSelector($0.selector) }.joined(separator: ", "), privacy: .public)"
        )
        return matching
    }

    private static func matchesHost(_ descriptors: [RuntimeMethodHook.Descriptor]) -> Bool {
        descriptors.allSatisfy { descriptor in
            RuntimeMethodInspector.hasMethod(
                className: descriptor.className,
                selector: descriptor.selector,
                matchingTypeEncoding: descriptor.expectedTypeEncoding,
                isInstanceMethod: descriptor.isInstanceMethod
            )
        }
    }
}

/// macOS 27's spelling of the Dock's own icon path, where the glass compositing filter is an argument.
///
/// Every tile the Dock draws for itself comes through here, so the substitution is kept to one question
/// asked in one place: ``DockAppsIconOverride/substituteImage(for:replacing:)``, which answers nil for
/// every tile but Apps and for Apps while the override is off.
@RuntimeClassHook("Tile")
struct DockTileIconHooksWithCompositingFilter {
    /// `image` is a `CGImageRef`, typed as an object because that is how the Dock declares it;
    /// `glassCompositingFilter` is forwarded untouched, so the tile keeps macOS 27's clear-icon treatment.
    @RuntimeMethodReplacement
    func setImage(_ image: AnyObject?, preferredGlassBackgroundStyle: Int, glassCompositingFilter: AnyObject?) {
        let substituteImage = DockAppsIconOverride.substituteImage(for: host, replacing: image)
        callOriginal(substituteImage ?? image, preferredGlassBackgroundStyle, glassCompositingFilter)
    }
}

/// macOS 26's spelling, where the glass compositing filter is a property of the tile and not an argument.
@RuntimeClassHook("Tile")
struct DockTileIconHooksWithoutCompositingFilter {
    @RuntimeMethodReplacement
    func setImage(_ image: AnyObject?, preferredGlassBackgroundStyle: Int) {
        let substituteImage = DockAppsIconOverride.substituteImage(for: host, replacing: image)
        callOriginal(substituteImage ?? image, preferredGlassBackgroundStyle)
    }
}
