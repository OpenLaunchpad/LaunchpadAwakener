import CoreGraphics
import Foundation
import LaunchpadAwakenerHookKit
import ObjectiveC
import OSLog
import QuartzCore

/// The Dock's own window class, called from the payload.
///
/// macOS 15's Launchpad drew into a `WALayerKitWindow` created on the Dock's connection; macOS 27.2's
/// Dock still has that class with the same initialiser. Every method below is checked against the
/// live host before anything calls it: a call with a wrong signature puts arguments in the wrong
/// registers inside someone else's process.
enum DockHostInterface {
    private static let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockHostInterface")

    private struct RequiredMethod {
        let className: String
        let selectorName: String
        /// Derived from the 27.2 (2571.1.32.402) Objective-C metadata. Frame offsets are ignored
        /// by the comparison; the live encoding is logged whenever this does not match.
        let expectedTypeEncoding: String
    }

    private static let initialiserSelectorName = "initWithFrame:connection:display:tags:level:"

    private static let requiredMethods: [RequiredMethod] = [
        RequiredMethod(
            className: "WALayerKitWindow",
            selectorName: initialiserSelectorName,
            expectedTypeEncoding: "@68@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16I48I52Q56i64"
        ),
        RequiredMethod(className: "WALayerKitWindow", selectorName: "layer", expectedTypeEncoding: "@16@0:8"),
        RequiredMethod(className: "WALayerKitWindow", selectorName: "wid", expectedTypeEncoding: "I16@0:8"),
        RequiredMethod(className: "WALayerKitWindow", selectorName: "order:otherWindow:", expectedTypeEncoding: "v24@0:8i16I20"),
    ]

    /// Whether every method the prototype calls exists with the expected signature. Logs the live
    /// encoding of each one, so a mismatch after a system update can be fixed from the log alone.
    static var isCompatible: Bool {
        var isEveryMethodCompatible = true
        for requiredMethod in requiredMethods {
            let selector = NSSelectorFromString(requiredMethod.selectorName)
            let liveTypeEncoding = MethodHookInspector.typeEncoding(forClassNamed: requiredMethod.className, selector: selector)
            let isMatching = liveTypeEncoding.map { MethodHookInspector.typeEncodingsMatch(requiredMethod.expectedTypeEncoding, $0) } ?? false
            logger.info(
                "-[\(requiredMethod.className, privacy: .public) \(requiredMethod.selectorName, privacy: .public)] live encoding \(liveTypeEncoding ?? "missing", privacy: .public), matches: \(isMatching, privacy: .public)"
            )
            isEveryMethodCompatible = isEveryMethodCompatible && isMatching
        }
        return isEveryMethodCompatible
    }

    /// Creates a window on `connectionIdentifier`, the way macOS 15's `-[Springboard init]` did.
    static func makeLayerKitWindow(
        frame: CGRect,
        connectionIdentifier: UInt32,
        displayIdentifier: CGDirectDisplayID,
        tags: UInt64,
        level: Int32
    ) -> NSObject? {
        typealias InitialiserFunction = @convention(c) (AnyObject, Selector, CGRect, UInt32, UInt32, UInt64, Int32) -> Unmanaged<AnyObject>?
        let selector = NSSelectorFromString(initialiserSelectorName)
        guard
            let windowClass = NSClassFromString("WALayerKitWindow") as? NSObject.Type,
            let initialiserImplementation = class_getMethodImplementation(windowClass, selector)
        else {
            logger.error("WALayerKitWindow or its initialiser is missing")
            return nil
        }
        let initialiser = unsafeBitCast(initialiserImplementation, to: InitialiserFunction.self)
        // alloc without init; the initialiser below consumes this reference and returns +1.
        let allocatedWindow = windowClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        guard let initialisedWindow = initialiser(allocatedWindow, selector, frame, connectionIdentifier, displayIdentifier, tags, level) else {
            logger.error("WALayerKitWindow initialiser returned nil")
            return nil
        }
        return initialisedWindow.takeRetainedValue() as? NSObject
    }

    static func rootLayer(of window: NSObject) -> CALayer? {
        window.perform(NSSelectorFromString("layer"))?.takeUnretainedValue() as? CALayer
    }

    static func windowIdentifier(of window: NSObject) -> UInt32 {
        typealias WindowIdentifierFunction = @convention(c) (AnyObject, Selector) -> UInt32
        let selector = NSSelectorFromString("wid")
        let implementation = unsafeBitCast(window.method(for: selector), to: WindowIdentifierFunction.self)
        return implementation(window, selector)
    }

    /// `order` follows the window server: 1 orders above everything else at the same level, 0 orders out.
    static func order(_ window: NSObject, order: Int32) {
        typealias OrderFunction = @convention(c) (AnyObject, Selector, Int32, UInt32) -> Void
        let selector = NSSelectorFromString("order:otherWindow:")
        let implementation = unsafeBitCast(window.method(for: selector), to: OrderFunction.self)
        implementation(window, selector, order, 0)
    }
}
