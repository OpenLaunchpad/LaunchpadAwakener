import CoreGraphics
import Foundation
import LaunchpadAwakenerHookKit
import ObjectiveC
import OSToolbox
import QuartzCore

/// One Dock method the payload calls, with the signature the call was written against.
struct DockMethodSignature: Sendable {
    let className: String
    let selectorName: String
    /// Read from the Dock's Objective-C metadata, never derived from a decompiler. Frame offsets are
    /// ignored by the comparison.
    let typeEncoding: String

    var selector: Selector {
        NSSelectorFromString(selectorName)
    }
}

/// Every call from the payload into the Dock's own classes goes through here.
///
/// A call with a wrong signature puts arguments in the wrong registers inside someone else's process,
/// so each method is checked against the live Dock once, before any hook is installed: if one does
/// not match, the payload installs nothing and the Dock keeps its own behaviour.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockHostInterface")
enum DockHostInterface {
    // MARK: - Signatures

    /// `-[WALayerKitWindow initWithFrame:connection:display:tags:level:]`, what macOS 15's
    /// `-[Springboard init]` created its window with.
    static let layerKitWindowInitialiser = DockMethodSignature(
        className: "WALayerKitWindow",
        selectorName: "initWithFrame:connection:display:tags:level:",
        typeEncoding: "@68@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16I48I52Q56i64"
    )
    static let layerKitWindowLayer = DockMethodSignature(
        className: "WALayerKitWindow",
        selectorName: "layer",
        typeEncoding: "@16@0:8"
    )
    static let layerKitWindowIdentifier = DockMethodSignature(
        className: "WALayerKitWindow",
        selectorName: "wid",
        typeEncoding: "I16@0:8"
    )
    static let layerKitWindowOrder = DockMethodSignature(
        className: "WALayerKitWindow",
        selectorName: "order:otherWindow:",
        typeEncoding: "v24@0:8i16I20"
    )
    /// `-[DockBar rect]`: global coordinates with a top-left origin, the space of `CGEvent.location`.
    static let dockBarRect = DockMethodSignature(
        className: "DockBar",
        selectorName: "rect",
        typeEncoding: "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8"
    )

    static let requiredMethods: [DockMethodSignature] = [
        layerKitWindowInitialiser,
        layerKitWindowLayer,
        layerKitWindowIdentifier,
        layerKitWindowOrder,
        dockBarRect,
    ] + DockLayerFactory.requiredMethods + DockEnvironment.requiredMethods

    /// Whether every method the payload calls exists with the expected signature.
    ///
    /// Logs the live encoding of each mismatch, so a system update can be adapted to from the log alone.
    static let isCompatible: Bool = checkRequiredMethods()

    private static func checkRequiredMethods() -> Bool {
        var mismatchCount = 0
        for requiredMethod in requiredMethods {
            let isMatching = MethodHookInspector.hasMethod(
                className: requiredMethod.className,
                selector: requiredMethod.selector,
                matchingTypeEncoding: requiredMethod.typeEncoding
            )
            guard !isMatching else { continue }
            mismatchCount += 1
            let liveTypeEncoding = MethodHookInspector.typeEncoding(
                forClassNamed: requiredMethod.className,
                selector: requiredMethod.selector
            )
            #log(.error, "-[\(requiredMethod.className, privacy: .public) \(requiredMethod.selectorName, privacy: .public)] expected \(requiredMethod.typeEncoding, privacy: .public), found \(liveTypeEncoding ?? "nothing", privacy: .public)")
        }
        #log(.info, "Checked \(requiredMethods.count, privacy: .public) Dock method(s), \(mismatchCount, privacy: .public) mismatch(es)")
        return mismatchCount == 0
    }

    // MARK: - WALayerKitWindow

    /// Creates a window on `connectionIdentifier`, the way macOS 15's `-[Springboard init]` did.
    static func makeLayerKitWindow(
        frame: CGRect,
        connectionIdentifier: UInt32,
        displayIdentifier: CGDirectDisplayID,
        tags: UInt64,
        level: Int32
    ) -> NSObject? {
        typealias InitialiserFunction = @convention(c) (AnyObject, Selector, CGRect, UInt32, UInt32, UInt64, Int32) -> Unmanaged<AnyObject>?
        let signature = layerKitWindowInitialiser
        guard
            let windowClass = NSClassFromString(signature.className) as? NSObject.Type,
            let initialiserImplementation = class_getMethodImplementation(windowClass, signature.selector)
        else {
            #log(.error, "WALayerKitWindow or its initialiser is missing")
            return nil
        }
        let initialiser = unsafeBitCast(initialiserImplementation, to: InitialiserFunction.self)
        // alloc without init; the initialiser consumes this reference and returns +1.
        guard let allocatedWindow = windowClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else {
            return nil
        }
        guard let initialisedWindow = initialiser(allocatedWindow, signature.selector, frame, connectionIdentifier, displayIdentifier, tags, level) else {
            #log(.error, "WALayerKitWindow initialiser returned nil")
            return nil
        }
        return initialisedWindow.takeRetainedValue() as? NSObject
    }

    static func rootLayer(of window: NSObject) -> CALayer? {
        typealias LayerFunction = @convention(c) (AnyObject, Selector) -> Unmanaged<CALayer>?
        let selector = layerKitWindowLayer.selector
        let implementation = unsafeBitCast(window.method(for: selector), to: LayerFunction.self)
        return implementation(window, selector)?.takeUnretainedValue()
    }

    static func windowIdentifier(of window: NSObject) -> UInt32 {
        typealias WindowIdentifierFunction = @convention(c) (AnyObject, Selector) -> UInt32
        let selector = layerKitWindowIdentifier.selector
        let implementation = unsafeBitCast(window.method(for: selector), to: WindowIdentifierFunction.self)
        return implementation(window, selector)
    }

    /// `ordering` follows the window server: 1 orders above every other window at the same level, 0 orders out.
    static func order(_ window: NSObject, ordering: Int32) {
        typealias OrderFunction = @convention(c) (AnyObject, Selector, Int32, UInt32) -> Void
        let selector = layerKitWindowOrder.selector
        let implementation = unsafeBitCast(window.method(for: selector), to: OrderFunction.self)
        implementation(window, selector, ordering, 0)
    }

    // MARK: - DockBar

    static func rect(of dockBar: NSObject) -> CGRect {
        typealias RectFunction = @convention(c) (AnyObject, Selector) -> CGRect
        let selector = dockBarRect.selector
        let implementation = unsafeBitCast(dockBar.method(for: selector), to: RectFunction.self)
        return implementation(dockBar, selector)
    }
}
