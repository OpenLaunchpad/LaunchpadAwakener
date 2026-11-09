import CoreGraphics
import Foundation
import ObjCRuntimeToolbox
import OSToolbox
import QuartzCore

@RuntimeClassProxy("DockGlassMaterialLayerController")
protocol DockGlassMaterialLayerController {
    /// Placed by the controller itself, at the frame given to ``DockGlassMaterial/update(frame:cornerRadius:isDark:displayScale:backdropGroupName:)``
    /// in its superlayer; geometry-flipped, and hit-tests as opaque.
    var rootLayer: CALayer? { get }
    func updateUsingLayoutConfiguration(_ configuration: AnyObject, environment: AnyObject)
}

@RuntimeClassProxy("DockGlassMaterialLayoutConfiguration")
protocol DockGlassMaterialLayoutConfiguration {
    func setFrame(_ frame: CGRect)
    /// Only `DockSDFElement`s may go in: the Dock casts every element to it.
    func setElements(_ elements: NSArray)
}

/// `DockSDFElement`, one shape of the glass, drawn as a signed distance field.
@RuntimeClassProxy("DockSDFElement")
protocol DockSignedDistanceFieldElement {
    /// Relative to the glass's root layer, whose origin is its top-left corner.
    func setUntransformedFrame(_ frame: CGRect)
    func setCornerRadius(_ cornerRadius: Double)
}

@RuntimeClassProxy("DockGlassMaterialEnvironment")
protocol DockGlassMaterialEnvironment {
    func setBackdropGroupName(_ backdropGroupName: NSString)
    func setDisplayScale(_ displayScale: Double)
}

/// The Dock's own Liquid Glass — what draws the Dock and the Command-Tab switcher — as one rectangle.
///
/// The glass is Swift inside the Dock, reachable through four Objective-C classes:
/// `DockGlassMaterialLayerController`, `DockGlassMaterialLayoutConfiguration`, `DockSDFElement` and
/// `DockGlassMaterialEnvironment`. They are driven here the way
/// `-[BezelIconListLayer _setMaterialLayerFrame:tileSize:]` (27.2 `0x10005EA04`) drives them for the
/// Command-Tab switcher. The blur is a window-server-aware `CABackdropLayer`, so the glass shows whatever
/// lies behind the window, other applications' windows included.
///
/// The signatures are not in ``DockHostInterface/requiredMethods``: they are checked on first use, and a
/// Dock without them only loses the glass.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockGlassMaterial")
@MainActor
final class DockGlassMaterial {
    // MARK: - Signatures

    static let controllerInitialiser = DockMethodSignature(
        className: "DockGlassMaterialLayerController",
        selectorName: "initWithVariant:adaptive:",
        typeEncoding: "@28@0:8q16B24"
    )
    /// A class method. It reads the Dock's `DockBar` and `DockGlobals` and traps when either does not
    /// exist yet, so it is only called once both are there.
    static let controllerEnvironment = DockMethodSignature(
        className: "DockGlassMaterialLayerController",
        selectorName: "currentDockMaterialEnvironmentWithColorScheme:",
        typeEncoding: "@24@0:8q16"
    )

    private static let instanceMethods: [DockMethodSignature] = [controllerInitialiser]
        + DockMethodSignature.signatures(
            ofClassNamed: DockGlassMaterialLayerControllerImplementation.runtimeClassName,
            requirements: DockGlassMaterialLayerControllerImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockGlassMaterialLayoutConfigurationImplementation.runtimeClassName,
            requirements: DockGlassMaterialLayoutConfigurationImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockSignedDistanceFieldElementImplementation.runtimeClassName,
            requirements: DockSignedDistanceFieldElementImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockGlassMaterialEnvironmentImplementation.runtimeClassName,
            requirements: DockGlassMaterialEnvironmentImplementation.methodRequirements
        )

    /// Whether the running Dock has the glass with the signatures this was written against.
    static let isAvailable: Bool = checkSignatures()

    private static func checkSignatures() -> Bool {
        var mismatchedNames = instanceMethods.compactMap { signature -> String? in
            RuntimeMethodInspector.hasMethod(className: signature.className, selector: signature.selector, matchingTypeEncoding: signature.typeEncoding)
                ? nil
                : "-[\(signature.className) \(signature.selectorName)]"
        }
        if !RuntimeMethodInspector.hasMethod(
            className: controllerEnvironment.className,
            selector: controllerEnvironment.selector,
            matchingTypeEncoding: controllerEnvironment.typeEncoding,
            isInstanceMethod: false
        ) {
            mismatchedNames.append("+[\(controllerEnvironment.className) \(controllerEnvironment.selectorName)]")
        }
        guard mismatchedNames.isEmpty else {
            #log(.error, "The Dock's glass is missing or changed (\(mismatchedNames.joined(separator: ", "), privacy: .public)); the background falls back to a plain blur")
            return false
        }
        return true
    }

    // MARK: - Glass

    /// The glass's layers. The controller places this layer itself, at the frame given to ``update(frame:cornerRadius:isDark:displayScale:backdropGroupName:)``
    /// in its superlayer; it is geometry-flipped, and hit-tests as opaque.
    let rootLayer: CALayer
    private let controller: DockGlassMaterialLayerControllerImplementation

    /// `variant` is the Dock's: 0 its own glass, 2 the same without foreground effects, 4 the
    /// Command-Tab switcher's. `isAdaptive` lets the glass turn light or dark with what is behind it.
    init?(variant: Int, isAdaptive: Bool) {
        // Unavailable is already logged, once, by `checkSignatures()`.
        guard Self.isAvailable else { return nil }
        guard
            let controllerObject = ObjC.DockGlassMaterialLayerController(variant: variant, adaptive: isAdaptive).asObject,
            let controller = DockGlassMaterialLayerControllerImplementation(controllerObject),
            let rootLayer = controller.rootLayer
        else {
            #log(.error, "The Dock's glass controller could not be made")
            return nil
        }
        self.controller = controller
        self.rootLayer = rootLayer
    }

    /// Lays the glass out as one rounded rectangle filling `frame`, a rectangle in the root layer's
    /// superlayer, in the light or dark appearance. Returns false — and changes nothing — while the Dock's
    /// `DockBar` or `DockGlobals` does not exist yet. Not animated.
    @discardableResult
    func update(frame: CGRect, cornerRadius: CGFloat, isDark: Bool, displayScale: CGFloat, backdropGroupName: String) -> Bool {
        guard
            DockBarReference.dockBar != nil,
            DockBarReference.dockGlobals != nil,
            let configurationObject = Self.makeObject(ofClassNamed: DockGlassMaterialLayoutConfigurationImplementation.runtimeClassName),
            let configuration = DockGlassMaterialLayoutConfigurationImplementation(configurationObject),
            let elementObject = Self.makeObject(ofClassNamed: DockSignedDistanceFieldElementImplementation.runtimeClassName),
            let element = DockSignedDistanceFieldElementImplementation(elementObject),
            let environmentObject = Self.currentEnvironment(isDark: isDark),
            let environment = DockGlassMaterialEnvironmentImplementation(environmentObject)
        else { return false }

        element.setUntransformedFrame(CGRect(origin: .zero, size: frame.size))
        element.setCornerRadius(Double(cornerRadius))
        configuration.setFrame(frame)
        configuration.setElements([elementObject] as NSArray)
        environment.setBackdropGroupName(backdropGroupName as NSString)
        environment.setDisplayScale(Double(displayScale))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        controller.updateUsingLayoutConfiguration(configurationObject, environment: environmentObject)
        CATransaction.commit()
        return true
    }

    // MARK: - Calls

    private static func makeObject(ofClassNamed className: String) -> NSObject? {
        (NSClassFromString(className) as? NSObject.Type)?.init()
    }

    /// `+currentDockMaterialEnvironmentWithColorScheme:`, which also reads the Dock's accessibility
    /// settings, its display's scale and the glass tint the user chose. The color scheme is the `q` the
    /// class method takes, 1 for dark.
    private static func currentEnvironment(isDark: Bool) -> NSObject? {
        let colorScheme: Int = isDark ? 1 : 0
        return DynamicObject(className: controllerEnvironment.className)
            .currentDockMaterialEnvironmentWithColorScheme(colorScheme)
            .asObject
    }
}
