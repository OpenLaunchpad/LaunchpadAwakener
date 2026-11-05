import Foundation
import ObjectiveC

/// Describes one Objective-C method implementation swap that a payload wants to install.
///
/// A descriptor is declarative on purpose: it names the target by string and selector rather
/// than by a compile-time symbol, because payloads hook classes that live in the host process
/// and are unavailable at build time. `MethodHookInstaller` validates every field before
/// touching any method, so a descriptor that no longer matches the host — a renamed class, a
/// changed signature after an operating system update — is rejected instead of corrupting the
/// host process.
public struct MethodHookDescriptor: Sendable {
    /// Name of the Objective-C class that declares the method, resolved with `objc_getClass`.
    public let className: String

    /// Selector of the method to replace.
    public let selector: Selector

    /// Whether the method is an instance method (`true`) or a class method (`false`).
    public let isInstanceMethod: Bool

    /// The method type encoding this descriptor was written against, as produced by
    /// `method_getTypeEncoding`.
    ///
    /// The installer compares this against the live encoding and refuses to install on any
    /// mismatch. This is the single most valuable safety check in the whole pipeline: a method
    /// whose parameter list changed under us would otherwise be called through a replacement
    /// built for the old signature, which corrupts registers and crashes the host.
    ///
    /// Obtain the value for a new hook with ``MethodHookInspector/typeEncoding(forClassNamed:selector:isInstanceMethod:)``
    /// rather than hand-writing it.
    public let expectedTypeEncoding: String

    /// Builds the replacement implementation, given the original one.
    ///
    /// Implement this by returning `imp_implementationWithBlock` over a block whose signature
    /// matches ``expectedTypeEncoding`` — first block parameter is the receiver, the selector is
    /// *not* passed. Capture `originalImplementation` to forward to the host's behaviour; cast it
    /// to a `@convention(c)` function type matching the same encoding.
    public let makeReplacement: @Sendable (_ originalImplementation: IMP) -> IMP

    public init(
        className: String,
        selector: Selector,
        isInstanceMethod: Bool = true,
        expectedTypeEncoding: String,
        makeReplacement: @escaping @Sendable (_ originalImplementation: IMP) -> IMP
    ) {
        self.className = className
        self.selector = selector
        self.isInstanceMethod = isInstanceMethod
        self.expectedTypeEncoding = expectedTypeEncoding
        self.makeReplacement = makeReplacement
    }
}

extension MethodHookDescriptor: CustomStringConvertible {
    public var description: String {
        let methodTypeMarker = isInstanceMethod ? "-" : "+"
        return "\(methodTypeMarker)[\(className) \(NSStringFromSelector(selector))]"
    }
}
