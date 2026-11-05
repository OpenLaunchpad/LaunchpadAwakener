import CoreGraphics
import Foundation
import LaunchpadAwakenerHookKit
import ObjectiveC

/// Application icons from IconServices, the way the Dock gets its own tile images.
///
/// The Dock goes from an `LSBinding` (`-[ISIcon initWithBinding:]`); this goes from the bundle URL
/// with `-[ISIcon initWithURL:]`, which needs no private C function. Every method is checked on the
/// object actually returned; any mismatch means no icon rather than a wrong call.
enum IconServicesBridge {
    private static let initialiseWithURLSelector = NSSelectorFromString("initWithURL:")
    private static let prepareImagesSelector = NSSelectorFromString("prepareImagesForImageDescriptors:")
    private static let imageForDescriptorSelector = NSSelectorFromString("imageForImageDescriptor:")
    private static let cgImageSelector = NSSelectorFromString("CGImage")
    private static let setSizeSelector = NSSelectorFromString("setSize:")
    private static let setScaleSelector = NSSelectorFromString("setScale:")

    /// A descriptor for `pointSize` at `scale`: a copy of `template` — the Dock's, which carries the
    /// icon style — or a plain `ISImageDescriptor`.
    static func makeDescriptor(copying template: NSObject?, pointSize: CGFloat, scale: CGFloat) -> NSObject? {
        let descriptor: NSObject
        if let template, let copiedDescriptor = template.copy() as? NSObject {
            descriptor = copiedDescriptor
        } else if let descriptorClass = NSClassFromString("ISImageDescriptor") as? NSObject.Type {
            descriptor = descriptorClass.init()
        } else {
            return nil
        }
        guard
            hasMethod(descriptor, setSizeSelector, typeEncoding: "v32@0:8{CGSize=dd}16"),
            hasMethod(descriptor, setScaleSelector, typeEncoding: "v24@0:8d16")
        else { return nil }
        typealias SetSizeFunction = @convention(c) (AnyObject, Selector, CGSize) -> Void
        typealias SetScaleFunction = @convention(c) (AnyObject, Selector, Double) -> Void
        unsafeBitCast(descriptor.method(for: setSizeSelector), to: SetSizeFunction.self)(descriptor, setSizeSelector, CGSize(width: pointSize, height: pointSize))
        unsafeBitCast(descriptor.method(for: setScaleSelector), to: SetScaleFunction.self)(descriptor, setScaleSelector, Double(scale))
        return descriptor
    }

    /// The icon of the file or bundle at `fileURL`, rendered for `descriptor`. Blocks while
    /// IconServices renders, so call it off the main thread.
    static func makeIconImage(forFileAt fileURL: URL, descriptor: NSObject) -> CGImage? {
        guard
            let iconClass = NSClassFromString("ISIcon") as? NSObject.Type,
            let allocatedIcon = iconClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
            hasMethod(allocatedIcon, initialiseWithURLSelector, typeEncoding: "@24@0:8@16")
        else { return nil }
        typealias InitialiserFunction = @convention(c) (AnyObject, Selector, NSURL) -> Unmanaged<NSObject>?
        let initialiser = unsafeBitCast(allocatedIcon.method(for: initialiseWithURLSelector), to: InitialiserFunction.self)
        guard let icon = initialiser(allocatedIcon, initialiseWithURLSelector, fileURL as NSURL)?.takeRetainedValue() else { return nil }

        guard
            hasMethod(icon, prepareImagesSelector, typeEncoding: "v24@0:8@16"),
            hasMethod(icon, imageForDescriptorSelector, typeEncoding: "@24@0:8@16")
        else { return nil }
        typealias PrepareFunction = @convention(c) (AnyObject, Selector, NSArray) -> Void
        typealias ImageFunction = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<NSObject>?
        unsafeBitCast(icon.method(for: prepareImagesSelector), to: PrepareFunction.self)(icon, prepareImagesSelector, [descriptor] as NSArray)
        guard
            let image = unsafeBitCast(icon.method(for: imageForDescriptorSelector), to: ImageFunction.self)(icon, imageForDescriptorSelector, descriptor)?
                .takeUnretainedValue(),
            hasMethod(image, cgImageSelector, typeEncoding: "^{CGImage=}16@0:8")
        else { return nil }
        typealias CGImageFunction = @convention(c) (AnyObject, Selector) -> Unmanaged<CGImage>?
        return unsafeBitCast(image.method(for: cgImageSelector), to: CGImageFunction.self)(image, cgImageSelector)?.takeUnretainedValue()
    }

    private static func hasMethod(_ object: NSObject, _ selector: Selector, typeEncoding expectedTypeEncoding: String) -> Bool {
        guard let method = class_getInstanceMethod(object_getClass(object), selector), let encoding = method_getTypeEncoding(method) else { return false }
        return MethodHookInspector.typeEncodingsMatch(String(cString: encoding), expectedTypeEncoding)
    }
}
