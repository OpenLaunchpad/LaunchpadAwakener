import CoreGraphics
import Foundation
import ObjectiveC
import OSToolbox
import LaunchpadAwakenerSpringboardCore

/// The Dock's `DockBar` and `DockGlobals`, read from the globals listed in the build profile.
///
/// macOS 15's `-[DockAppEventHandler handleSpringboardEvent:type:]` compared every click with
/// `-[DockBar rect]` to leave clicks on the Dock to the Dock. On macOS 27.2 nothing exported leads to
/// the `DockBar`, and neither `rect` nor `setRollTile:` is called while the pointer moves over the
/// Dock, so observing those methods never finds it — the global is the only way in.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockBarReference")
@MainActor
enum DockBarReference {
    private static weak var cachedDockBar: NSObject?
    private static weak var cachedDockGlobals: NSObject?

    /// The Dock's `DockBar`; nil when it cannot be found.
    static var dockBar: NSObject? {
        if let cachedDockBar {
            return cachedDockBar
        }
        let resolvedDockBar = DockBuildProfile.current.flatMap { profile in
            readGlobalObject(atUnslidAddress: profile.dockBarGlobalAddress, expectedClassName: "DockBar")
        }
        cachedDockBar = resolvedDockBar
        return resolvedDockBar
    }

    /// The Dock's `DockGlobals`; nil when it cannot be found or does not exist yet.
    static var dockGlobals: NSObject? {
        if let cachedDockGlobals {
            return cachedDockGlobals
        }
        let resolvedDockGlobals = DockBuildProfile.current.flatMap { profile in
            readGlobalObject(atUnslidAddress: profile.dockGlobalsGlobalAddress, expectedClassName: profile.dockGlobalsClassName)
        }
        cachedDockGlobals = resolvedDockGlobals
        return resolvedDockGlobals
    }

    /// The bar's current rectangle in global coordinates with a top-left origin; nil when the
    /// `DockBar` cannot be found.
    static var currentBarRect: CGRect? {
        dockBar.flatMap { DockBarGeometryImplementation($0)?.rect }
    }

    /// Reads a global of the running Dock, and accepts what it holds only when that turns out to be an
    /// instance of `expectedClassName`.
    private static func readGlobalObject(atUnslidAddress unslidAddress: UInt, expectedClassName: String) -> NSObject? {
        let globalAddress = Int(bitPattern: unslidAddress) + DockBuildProfile.executableSlide
        guard
            let globalPointer = UnsafeRawPointer(bitPattern: globalAddress),
            let objectPointer = globalPointer.load(as: UnsafeRawPointer?.self)
        else {
            #log(.error, "The \(expectedClassName, privacy: .public) global is empty")
            return nil
        }
        let object = Unmanaged<AnyObject>.fromOpaque(objectPointer).takeUnretainedValue()
        // Compared as classes: the runtime names a Swift class `DockCore.DockGlobals`, not by the mangled
        // name it is looked up by.
        guard
            let expectedClass = NSClassFromString(expectedClassName),
            let objectClass = object_getClass(object),
            objectClass == expectedClass,
            let typedObject = object as? NSObject
        else {
            #log(.error, "The \(expectedClassName, privacy: .public) global holds a \(String(cString: object_getClassName(object)), privacy: .public); ignoring it")
            return nil
        }
        return typedObject
    }
}
