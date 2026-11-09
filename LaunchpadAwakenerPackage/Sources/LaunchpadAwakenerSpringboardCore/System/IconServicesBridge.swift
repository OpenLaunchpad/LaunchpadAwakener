import CoreGraphics
import Foundation
import ObjCRuntimeToolbox

/// Application icons from IconServices, the way the Dock gets its own tile images.
///
/// The Dock goes from an `LSBinding` (`-[ISIcon initWithBinding:]`); this goes from the bundle URL
/// with `-[ISIcon initWithURL:]`, which needs no private C function. The objects come back as whatever
/// class IconServices picks — an image is only known to follow the `ISImage` protocol — so every method
/// is checked on the object actually returned and then called through `DynamicObject`; any mismatch means
/// no icon rather than a wrong call.
enum IconServicesBridge {
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
            hasMethod(descriptor, "setSize:", typeEncoding: "v32@0:8{CGSize=dd}16"),
            hasMethod(descriptor, "setScale:", typeEncoding: "v24@0:8d16")
        else { return nil }
        ObjC(descriptor).setSize(CGSize(width: pointSize, height: pointSize))
        ObjC(descriptor).setScale(Double(scale))
        return descriptor
    }

    /// The icon of the file or bundle at `fileURL`, rendered for `descriptor`. Blocks while
    /// IconServices renders, so call it off the main thread.
    ///
    /// `ISIcon` is a class cluster: `+alloc` hands out an `ISIconFactory`, and `initWithURL:` lives there,
    /// not on `ISIcon`, so the initialiser is checked on what `alloc` returned and sent to that object.
    static func makeIconImage(forFileAt fileURL: URL, descriptor: NSObject) -> CGImage? {
        let allocation: DynamicObject = ObjC.ISIcon[dynamicMember: "alloc"]
        guard
            let allocatedIcon = allocation.asObject,
            hasMethod(allocatedIcon, "initWithURL:", typeEncoding: "@24@0:8@16"),
            let icon = ObjC(allocatedIcon).initWithURL(fileURL as NSURL).asObject,
            hasMethod(icon, "prepareImagesForImageDescriptors:", typeEncoding: "v24@0:8@16"),
            hasMethod(icon, "imageForImageDescriptor:", typeEncoding: "@24@0:8@16")
        else { return nil }
        ObjC(icon).prepareImagesForImageDescriptors([descriptor] as NSArray)
        guard
            let image = ObjC(icon).imageForImageDescriptor(descriptor).asObject,
            hasMethod(image, "CGImage", typeEncoding: "^{CGImage=}16@0:8")
        else { return nil }
        // Read as an optional raw pointer, which may be null, rather than as a `CGImage`, which may not.
        let imageAddress: UnsafeRawPointer?? = ObjC(image).CGImage.asInferred()
        guard let imagePointer = imageAddress.flatMap({ $0 }) else { return nil }
        return Unmanaged<CGImage>.fromOpaque(imagePointer).takeUnretainedValue()
    }

    /// Whether `object`'s own class has `selectorName` with `expectedTypeEncoding`, frame offsets aside.
    private static func hasMethod(_ object: NSObject, _ selectorName: String, typeEncoding expectedTypeEncoding: String) -> Bool {
        guard
            let objectClass = object_getClass(object),
            let typeEncoding = RuntimeMethodInspector.typeEncoding(forClass: objectClass, selector: NSSelectorFromString(selectorName))
        else { return false }
        return ObjCTypeEncodingNormalization.matches(typeEncoding, expectedTypeEncoding)
    }
}
