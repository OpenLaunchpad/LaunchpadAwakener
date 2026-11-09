import CoreGraphics
import Foundation
import ObjCRuntimeToolbox
import OSToolbox
import LaunchpadAwakenerSpringboardCore

/// What the payload reads from the Dock's `DockBar`. Every one of these is among the methods checked
/// before any hook is installed.
@RuntimeClassProxy("DockBar")
protocol DockBarGeometry {
    /// Global coordinates with a top-left origin, the space of `CGEvent.location`.
    var rect: CGRect? { get }
    /// A `DisplayDescriptor`.
    var display: NSObject? { get }
    /// A `DockCore.Environment`.
    var environment: NSObject? { get }
    /// The icon size the Dock is set to.
    var desiredTileSize: Float? { get }
    /// The tile the Dock settled on: the icon size plus an inset on each side, smaller when the bar had to
    /// shrink to fit.
    var tileSize: Float? { get }
}

/// The display the Dock is on.
@RuntimeClassProxy("DisplayDescriptor")
protocol DockDisplayDescriptor {
    /// The camera housing; empty on a display without one.
    var notchBounds: CGRect? { get }
}

/// What the springboard needs to know about the Dock and its display, read from the Dock itself.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockEnvironment")
@MainActor
enum DockEnvironment {
    // MARK: - Signatures

    nonisolated static let requiredMethods: [DockMethodSignature] =
        DockMethodSignature.signatures(
            ofClassNamed: DockBarGeometryImplementation.runtimeClassName,
            requirements: DockBarGeometryImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockDisplayDescriptorImplementation.runtimeClassName,
            requirements: DockDisplayDescriptorImplementation.methodRequirements
        )

    // MARK: - Geometry

    /// The Dock's preference; the bar itself does not expose it.
    static var dockOrientation: DockOrientation {
        UserDefaults.standard.string(forKey: "orientation").flatMap(DockOrientation.init(rawValue:)) ?? .bottom
    }

    /// The room the springboard leaves the Dock, worked out from the Dock's tiles as macOS 15 did; 79 points
    /// at the default size. 27's glass bar is taller than that (94 points at the default size), so the
    /// springboard sits a little closer to it than 15's did to its Dock.
    static var dockThickness: CGFloat {
        guard let dockBar = DockBarReference.dockBar.flatMap({ DockBarGeometryImplementation($0) }) else {
            return SpringboardMetrics.defaultDockThickness
        }
        let desiredTileSize = dockBar.desiredTileSize ?? .nan
        let tileSize = dockBar.tileSize ?? .nan
        guard desiredTileSize.isFinite, tileSize.isFinite, tileSize > 0 else {
            #log(.error, "The Dock's tile size reads \(tileSize, privacy: .public) (set to \(desiredTileSize, privacy: .public)); leaving the default room")
            return SpringboardMetrics.defaultDockThickness
        }
        return SpringboardMetrics.dockThickness(desiredTileSize: desiredTileSize, tileSize: tileSize)
    }

    /// The camera housing's height on the Dock's display; zero without one.
    static var notchHeight: CGFloat {
        guard
            let display = DockBarReference.dockBar.flatMap({ DockBarGeometryImplementation($0)?.display }),
            let notchBounds = DockDisplayDescriptorImplementation(display)?.notchBounds
        else { return 0 }
        return notchBounds.height
    }

    // MARK: - Icon appearance

    /// The icon style the Dock draws its own tiles in, as `IconAppearance` holds it; the compositing filter
    /// that goes with it is ``SpringboardIconStyle/glassCompositingFilterName``.
    struct IconAppearance {
        /// An `ISImageDescriptor` set up for the current style; copy before changing it.
        let iconDescriptor: NSObject
        /// `IconStyle`: 0 and 1 default, 2 and 3 clear, 4 and 5 tinted (light and dark each).
        let style: UInt8
    }

    /// `DockBar.environment.iconAppearanceMonitor.appearance`; nil when any step is missing.
    ///
    /// The objects past the environment are Swift classes whose class is whatever the object turns out to
    /// be, so each member is checked on the object's own class and called through `DynamicObject`.
    /// Without them icons fall back to the default style.
    static var iconAppearance: IconAppearance? {
        guard
            let environment = environmentObject,
            let monitor = objectValue(of: environment, named: "iconAppearanceMonitor"),
            let appearance = objectValue(of: monitor, named: "appearance"),
            let iconDescriptor = objectValue(of: appearance, named: "iconDescription"),
            let style = checkedMember(of: appearance, named: "style", typeEncoding: "C16@0:8")?.asUInt8
        else {
            #log(.error, "The Dock's icon appearance is out of reach; icons use the default style")
            return nil
        }
        return IconAppearance(iconDescriptor: iconDescriptor, style: style)
    }

    // MARK: - Calls

    /// `DockBar.environment`, a `DockCore.Environment`; nil when the `DockBar` is out of reach.
    static var environmentObject: NSObject? {
        DockBarReference.dockBar.flatMap { DockBarGeometryImplementation($0)?.environment }
    }

    /// Whether `receiver`'s own class has `selector` with `expectedTypeEncoding`, frame offsets aside; logs
    /// when it does not.
    ///
    /// For objects whose class is not known in advance — the Dock's Swift classes reached through other
    /// objects — where a `@RuntimeClassProxy`, which names one class, does not fit.
    static func hasMethod(_ receiver: NSObject, selector: Selector, typeEncoding expectedTypeEncoding: String) -> Bool {
        guard
            let receiverClass = object_getClass(receiver),
            let encoding = RuntimeMethodInspector.typeEncoding(forClass: receiverClass, selector: selector),
            ObjCTypeEncodingNormalization.matches(encoding, expectedTypeEncoding)
        else {
            #log(.error, "-[\(String(cString: object_getClassName(receiver)), privacy: .public) \(NSStringFromSelector(selector), privacy: .public)] is missing or changed")
            return false
        }
        return true
    }

    /// `receiver.<memberName>`, a member that takes nothing, through `DynamicObject` — once ``hasMethod(_:selector:typeEncoding:)``
    /// has found it with `typeEncoding` on the receiver's own class.
    static func checkedMember(of receiver: NSObject, named memberName: String, typeEncoding: String) -> DynamicObject? {
        guard hasMethod(receiver, selector: NSSelectorFromString(memberName), typeEncoding: typeEncoding) else { return nil }
        let member: DynamicObject = DynamicObject(receiver)[dynamicMember: memberName]
        return member
    }

    /// An object-returning member that takes nothing, checked as ``checkedMember(of:named:typeEncoding:)``
    /// checks it.
    static func objectValue(of receiver: NSObject, named memberName: String) -> NSObject? {
        checkedMember(of: receiver, named: memberName, typeEncoding: "@16@0:8")?.asObject
    }
}
