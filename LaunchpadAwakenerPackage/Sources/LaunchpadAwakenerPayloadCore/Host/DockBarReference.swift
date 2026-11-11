import CoreGraphics
import Foundation
import ObjectiveC
import OSToolbox
import LaunchpadAwakenerPayloadInterface
import LaunchpadAwakenerSpringboardCore

/// The Dock's `DockBar` and `DockGlobals`, recognised in the host's own data sections by what they hold.
///
/// macOS 15's `-[DockAppEventHandler handleSpringboardEvent:type:]` compared every click with
/// `-[DockBar rect]` to leave clicks on the Dock to the Dock. On macOS 27.2 nothing exported leads to
/// the `DockBar`, and neither `rect` nor `setRollTile:` is called while the pointer moves over the Dock,
/// so observing those methods never finds it — a global is the only way in. The Dock is stripped, so the
/// only way to the global is to recognise it by what it holds: ``DockGlobalScanner``.
///
/// Both are looked up on first use and a failure is never cached. The payload can be injected within
/// 250 ms of the Dock starting, before it has built its singletons; by the time anything here is wanted
/// — a Launchpad key, a layout pass — the Dock has long been up.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockBarReference")
@MainActor
enum DockBarReference {
    private static weak var cachedDockBar: NSObject?
    private static weak var cachedDockGlobals: NSObject?

    /// Runtime name of the Dock's dock bar. The same on macOS 26 and 27.
    nonisolated static let dockBarClassName = "DockBar"

    /// Runtime names of the Dock's globals object, in the order they are tried.
    ///
    /// macOS 26 has an Objective-C class; macOS 27 rewrote it in Swift, whose runtime name is mangled.
    /// Whichever of them this system has a class for is the one searched for — which is what replaced
    /// the class name the build profile used to record for each Dock build.
    nonisolated static let dockGlobalsClassNames = ["DockGlobals", "_TtC8DockCore11DockGlobals"]

    /// What to call the globals object in anything a person reads. Neither runtime name is worth showing.
    nonisolated static let dockGlobalsDisplayName = "DockGlobals"

    /// The Dock's `DockBar`; nil when it cannot be found.
    static var dockBar: NSObject? {
        if let cachedDockBar { return cachedDockBar }
        let resolvedDockBar = findGlobalObject(
            ofAnyClassNamed: [dockBarClassName],
            in: DockGlobalScanner.mainExecutablePointerSlotRegions()
        )
        cachedDockBar = resolvedDockBar
        return resolvedDockBar
    }

    /// The Dock's `DockGlobals`; nil when it cannot be found or does not exist yet.
    static var dockGlobals: NSObject? {
        if let cachedDockGlobals { return cachedDockGlobals }
        let resolvedDockGlobals = findGlobalObject(
            ofAnyClassNamed: dockGlobalsClassNames,
            in: DockGlobalScanner.mainExecutablePointerSlotRegions()
        )
        cachedDockGlobals = resolvedDockGlobals
        return resolvedDockGlobals
    }

    /// Which of the globals the replica needs can be reached at this moment.
    ///
    /// Worked out when asked rather than recorded once, because the answer changes: the app asks every
    /// time the control panel refreshes, and a Dock that had not finished starting when the payload
    /// arrived answers differently a second later.
    ///
    /// `nonisolated`, and deliberately not reading the cache the two properties above keep. The app asks
    /// this from the payload's channel actor; hopping to the main actor to reuse the cache would make
    /// the answer wait on whatever the Dock's main thread is doing, and the app gives a status request
    /// two seconds before it gives up. A fresh scan is tens of microseconds and reads the same memory.
    nonisolated static var reachability: DockGlobalsReachability {
        let regions = DockGlobalScanner.mainExecutablePointerSlotRegions()
        var missingNames: [String] = []
        if findGlobalObject(ofAnyClassNamed: [dockBarClassName], in: regions) == nil {
            missingNames.append(dockBarClassName)
        }
        if findGlobalObject(ofAnyClassNamed: dockGlobalsClassNames, in: regions) == nil {
            missingNames.append(dockGlobalsDisplayName)
        }
        return missingNames.isEmpty ? .reachable : .unreachable(missingClassNames: missingNames)
    }

    /// The bar's current rectangle in global coordinates with a top-left origin; nil when the
    /// `DockBar` cannot be found.
    static var currentBarRect: CGRect? {
        dockBar.flatMap { DockBarGeometryImplementation($0)?.rect }
    }

    /// Looks for a global holding an instance of any of `classNames`, taking the first one found.
    ///
    /// Names this system has no class for are skipped rather than failed on: the list spans two macOS
    /// versions, so on either one most of it does not exist.
    ///
    /// `nonisolated` because it touches no stored state — the caching is the two properties' business,
    /// not this one's — which is what lets ``reachability`` answer without the main actor.
    private nonisolated static func findGlobalObject(
        ofAnyClassNamed classNames: [String],
        in regions: [PointerSlotRegion]
    ) -> NSObject? {
        let existingClasses = classNames.compactMap { className in
            NSClassFromString(className).map { (name: className, targetClass: $0) }
        }
        guard !existingClasses.isEmpty else {
            #log(.error, "This system has no class named \(classNames.joined(separator: " or "), privacy: .public)")
            return nil
        }
        for existingClass in existingClasses {
            guard
                case .found(let object, _) = DockGlobalScanner.findGlobal(
                    holdingInstanceOf: existingClass.targetClass,
                    in: regions
                )
            else { continue }
            guard let typedObject = object as? NSObject else {
                #log(.error, "The \(existingClass.name, privacy: .public) found is not an NSObject; ignoring it")
                continue
            }
            return typedObject
        }
        #log(
            .error,
            "No global of \(ProcessInfo.processInfo.processName, privacy: .public) holds a \(existingClasses.map(\.name).joined(separator: " or "), privacy: .public)"
        )
        return nil
    }
}
