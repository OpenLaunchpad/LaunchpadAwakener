import CoreGraphics
import Foundation
import ObjCRuntimeToolbox
import ObjectiveC
import OSToolbox
import QuartzCore

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
    static let controllerUpdate = DockMethodSignature(
        className: "DockGlassMaterialLayerController",
        selectorName: "updateUsingLayoutConfiguration:environment:",
        typeEncoding: "v32@0:8@16@24"
    )
    static let controllerRootLayer = DockMethodSignature(className: "DockGlassMaterialLayerController", selectorName: "rootLayer", typeEncoding: "@16@0:8")
    /// A class method. It reads the Dock's `DockBar` and `DockGlobals` and traps when either does not
    /// exist yet, so it is only called once both are there.
    static let controllerEnvironment = DockMethodSignature(
        className: "DockGlassMaterialLayerController",
        selectorName: "currentDockMaterialEnvironmentWithColorScheme:",
        typeEncoding: "@24@0:8q16"
    )
    static let configurationFrame = DockMethodSignature(
        className: "DockGlassMaterialLayoutConfiguration",
        selectorName: "setFrame:",
        typeEncoding: "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16"
    )
    /// Only `DockSDFElement`s may go in: the Dock casts every element to it.
    static let configurationElements = DockMethodSignature(className: "DockGlassMaterialLayoutConfiguration", selectorName: "setElements:", typeEncoding: "v24@0:8@16")
    /// Relative to the glass's root layer, whose origin is its top-left corner.
    static let elementFrame = DockMethodSignature(
        className: "DockSDFElement",
        selectorName: "setUntransformedFrame:",
        typeEncoding: "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16"
    )
    static let elementCornerRadius = DockMethodSignature(className: "DockSDFElement", selectorName: "setCornerRadius:", typeEncoding: "v24@0:8d16")
    static let environmentBackdropGroupName = DockMethodSignature(className: "DockGlassMaterialEnvironment", selectorName: "setBackdropGroupName:", typeEncoding: "v24@0:8@16")
    static let environmentDisplayScale = DockMethodSignature(className: "DockGlassMaterialEnvironment", selectorName: "setDisplayScale:", typeEncoding: "v24@0:8d16")

    private static let instanceMethods: [DockMethodSignature] = [
        controllerInitialiser,
        controllerUpdate,
        controllerRootLayer,
        configurationFrame,
        configurationElements,
        elementFrame,
        elementCornerRadius,
        environmentBackdropGroupName,
        environmentDisplayScale,
    ]

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
    private let controller: NSObject

    /// `variant` is the Dock's: 0 its own glass, 2 the same without foreground effects, 4 the
    /// Command-Tab switcher's. `isAdaptive` lets the glass turn light or dark with what is behind it.
    init?(variant: Int, isAdaptive: Bool) {
        guard Self.isAvailable, let controllerClass = NSClassFromString(Self.controllerInitialiser.className) as? NSObject.Type else { return nil }
        typealias InitialiserFunction = @convention(c) (AnyObject, Selector, Int, Bool) -> Unmanaged<NSObject>?
        typealias RootLayerFunction = @convention(c) (AnyObject, Selector) -> Unmanaged<CALayer>?
        guard
            let initialiserImplementation = class_getMethodImplementation(controllerClass, Self.controllerInitialiser.selector),
            // alloc without init; the initialiser consumes this reference and returns +1.
            let allocatedController = controllerClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
            let controller = unsafeBitCast(initialiserImplementation, to: InitialiserFunction.self)(
                allocatedController,
                Self.controllerInitialiser.selector,
                variant,
                isAdaptive
            )?.takeRetainedValue()
        else {
            #log(.error, "The Dock's glass controller could not be made")
            return nil
        }
        let rootLayerSelector = Self.controllerRootLayer.selector
        guard let rootLayer = unsafeBitCast(controller.method(for: rootLayerSelector), to: RootLayerFunction.self)(controller, rootLayerSelector)?.takeUnretainedValue() else {
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
            let configuration = Self.makeObject(ofClassNamed: Self.configurationFrame.className),
            let element = Self.makeObject(ofClassNamed: Self.elementFrame.className),
            let environment = Self.currentEnvironment(isDark: isDark)
        else { return false }

        Self.call(Self.elementFrame, on: element, with: CGRect(origin: .zero, size: frame.size))
        Self.call(Self.elementCornerRadius, on: element, with: Double(cornerRadius))
        Self.call(Self.configurationFrame, on: configuration, with: frame)
        Self.call(Self.configurationElements, on: configuration, with: [element] as NSArray)
        Self.call(Self.environmentBackdropGroupName, on: environment, with: backdropGroupName as NSString)
        Self.call(Self.environmentDisplayScale, on: environment, with: Double(displayScale))

        typealias UpdateFunction = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        let updateSelector = Self.controllerUpdate.selector
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        unsafeBitCast(controller.method(for: updateSelector), to: UpdateFunction.self)(controller, updateSelector, configuration, environment)
        CATransaction.commit()
        return true
    }

    // MARK: - Calls

    private static func makeObject(ofClassNamed className: String) -> NSObject? {
        (NSClassFromString(className) as? NSObject.Type)?.init()
    }

    /// `+currentDockMaterialEnvironmentWithColorScheme:`, which also reads the Dock's accessibility
    /// settings, its display's scale and the glass tint the user chose.
    private static func currentEnvironment(isDark: Bool) -> NSObject? {
        guard let controllerClass = NSClassFromString(controllerEnvironment.className) else { return nil }
        typealias EnvironmentFunction = @convention(c) (AnyObject, Selector, Int) -> Unmanaged<NSObject>?
        let selector = controllerEnvironment.selector
        guard let implementation = class_getMethodImplementation(object_getClass(controllerClass), selector) else { return nil }
        return unsafeBitCast(implementation, to: EnvironmentFunction.self)(controllerClass, selector, isDark ? 1 : 0)?.takeUnretainedValue()
    }

    private static func call(_ signature: DockMethodSignature, on receiver: NSObject, with rect: CGRect) {
        typealias RectSetterFunction = @convention(c) (AnyObject, Selector, CGRect) -> Void
        unsafeBitCast(receiver.method(for: signature.selector), to: RectSetterFunction.self)(receiver, signature.selector, rect)
    }

    private static func call(_ signature: DockMethodSignature, on receiver: NSObject, with value: Double) {
        typealias DoubleSetterFunction = @convention(c) (AnyObject, Selector, Double) -> Void
        unsafeBitCast(receiver.method(for: signature.selector), to: DoubleSetterFunction.self)(receiver, signature.selector, value)
    }

    private static func call(_ signature: DockMethodSignature, on receiver: NSObject, with object: AnyObject) {
        typealias ObjectSetterFunction = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(receiver.method(for: signature.selector), to: ObjectSetterFunction.self)(receiver, signature.selector, object)
    }
}
