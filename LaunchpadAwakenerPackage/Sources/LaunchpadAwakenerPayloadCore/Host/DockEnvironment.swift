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

/// Which display a `DisplayDescriptor` describes. Apart from ``DockDisplayDescriptor`` and not among the
/// methods checked before any hook goes in: a Dock without it only loses the choice of display, and the
/// springboard opens on the main display as it did before.
@RuntimeClassProxy("DisplayDescriptor")
protocol DockDisplayIdentity {
    /// The display's `CGDirectDisplayID`.
    var identifier: UInt32? { get }
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

    /// The display the Dock is on: `DockBar.display`, which a move to another display sets as it starts, and
    /// what macOS 15's `-[Springboard display]` read. `realDisplay` follows only once the Dock's window has
    /// left the old display. Nil when the `DockBar` or the identifier is out of reach.
    static var dockDisplayIdentifier: CGDirectDisplayID? {
        dockDisplay.flatMap { DockDisplayIdentityImplementation($0)?.identifier }
    }

    /// The camera housing's height on `displayIdentifier`; zero without one. The Dock describes only the
    /// display it is on, so another display counts as one without a camera housing.
    static func notchHeight(onDisplay displayIdentifier: CGDirectDisplayID) -> CGFloat {
        guard let display = dockDisplay else { return 0 }
        // A Dock whose descriptor does not say which display it is keeps the springboard on the main display,
        // which is where the descriptor was always taken to be before.
        if let dockDisplayIdentifier = DockDisplayIdentityImplementation(display)?.identifier, dockDisplayIdentifier != displayIdentifier {
            return 0
        }
        return DockDisplayDescriptorImplementation(display)?.notchBounds?.height ?? 0
    }

    /// `DockBar.display`, a `DisplayDescriptor`.
    private static var dockDisplay: NSObject? {
        DockBarReference.dockBar.flatMap { DockBarGeometryImplementation($0)?.display }
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
    /// Each object on the way is checked as the class it turns out to have — see
    /// ``DockEnvironmentIconAppearanceAccess``. Without them icons fall back to the default style.
    static var iconAppearance: IconAppearance? {
        guard
            let environment = environmentObject,
            let monitor = DockEnvironmentIconAppearanceAccessImplementation(environment)?.iconAppearanceMonitor,
            let appearance = DockIconAppearanceMonitorImplementation(monitor)?.appearance,
            let dockAppearance = DockIconAppearanceImplementation(appearance),
            let iconDescriptor = dockAppearance.iconDescription,
            let style = dockAppearance.style
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
}

// MARK: - Reached through the environment

// The environment and what it hands out are the Dock's Swift classes, reached through protocols the Dock
// declares, and their Objective-C class names are not stable: the environment is `Environment` in the
// 26.6.2 Dock and `_TtC8DockCore11Environment` in 27.2. So these proxies check whatever class each object
// turns out to have, the first time they meet it.

/// `DockCore.Environment`, as far as icon style goes.
@RuntimeObjectProxy
protocol DockEnvironmentIconAppearanceAccess {
    /// A `DockCore.SystemIconAppearanceMonitor`.
    var iconAppearanceMonitor: NSObject? { get }
}

/// `DockCore.SystemIconAppearanceMonitor`.
@RuntimeObjectProxy
protocol DockIconAppearanceMonitor {
    /// An `IconAppearance`.
    var appearance: NSObject? { get }
}

/// `IconAppearance`, the style the Dock draws its own tiles in.
@RuntimeObjectProxy
protocol DockIconAppearance {
    /// An `ISImageDescriptor` set up for the current style.
    var iconDescription: NSObject? { get }
    /// `IconStyle`, an `unsigned char`.
    var style: UInt8? { get }
}
