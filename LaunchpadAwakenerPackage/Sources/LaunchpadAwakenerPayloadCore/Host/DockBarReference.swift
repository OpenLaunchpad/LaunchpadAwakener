import CoreGraphics
import Foundation
import ObjectiveC
import OSToolbox

/// The Dock's `DockBar`, read from the global listed in the build profile.
///
/// macOS 15's `-[DockAppEventHandler handleSpringboardEvent:type:]` compared every click with
/// `-[DockBar rect]` to leave clicks on the Dock to the Dock. On macOS 27.2 nothing exported leads to
/// the `DockBar`, and neither `rect` nor `setRollTile:` is called while the pointer moves over the
/// Dock, so observing those methods never finds it — the global is the only way in.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockBarReference")
@MainActor
enum DockBarReference {
    private static weak var cachedDockBar: NSObject?

    /// The Dock's `DockBar`; nil when it cannot be found.
    static var dockBar: NSObject? {
        if let cachedDockBar {
            return cachedDockBar
        }
        let resolvedDockBar = readDockBarGlobal()
        cachedDockBar = resolvedDockBar
        return resolvedDockBar
    }

    /// The bar's current rectangle in global coordinates with a top-left origin; nil when the
    /// `DockBar` cannot be found.
    static var currentBarRect: CGRect? {
        dockBar.map(DockHostInterface.rect(of:))
    }

    /// Reads the global named by the running Dock's profile, and accepts what it holds only when that
    /// turns out to be a `DockBar`.
    private static func readDockBarGlobal() -> NSObject? {
        guard let profile = DockBuildProfile.current else { return nil }
        let globalAddress = Int(bitPattern: profile.dockBarGlobalAddress) + DockBuildProfile.executableSlide
        guard
            let globalPointer = UnsafeRawPointer(bitPattern: globalAddress),
            let objectPointer = globalPointer.load(as: UnsafeRawPointer?.self)
        else {
            #log(.error, "The DockBar global is empty")
            return nil
        }
        let object = Unmanaged<AnyObject>.fromOpaque(objectPointer).takeUnretainedValue()
        guard String(cString: object_getClassName(object)) == "DockBar", let dockBar = object as? NSObject else {
            #log(.error, "The DockBar global holds a \(String(cString: object_getClassName(object)), privacy: .public); ignoring it")
            return nil
        }
        return dockBar
    }
}
