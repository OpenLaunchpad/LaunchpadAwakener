import Foundation
import ObjectiveC
import OSLog

/// Why a batch of hooks was rejected.
public enum MethodHookInstallationFailure: Error, CustomStringConvertible {
    case classNotFound(className: String)
    case methodNotFound(className: String, selectorName: String)
    case typeEncodingMissing(className: String, selectorName: String)
    case typeEncodingMismatch(className: String, selectorName: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case .classNotFound(let className):
            return "class \(className) not found in this process"
        case .methodNotFound(let className, let selectorName):
            return "\(className) does not respond to \(selectorName)"
        case .typeEncodingMissing(let className, let selectorName):
            return "\(className) \(selectorName) has no type encoding"
        case .typeEncodingMismatch(let className, let selectorName, let expected, let actual):
            return "\(className) \(selectorName) signature changed — expected \(expected), found \(actual)"
        }
    }
}

/// Installs ``MethodHookDescriptor`` batches into the current process.
///
/// The installer is deliberately all-or-nothing. Every descriptor is resolved and signature-checked
/// first; only when the whole batch validates does it swap a single implementation. A payload that
/// half-installs is worse than one that does not install at all, because the host then runs a mix of
/// hooked and unhooked behaviour that no one designed or tested.
public enum MethodHookInstaller {
    private static let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakener", category: "MethodHookInstaller")

    /// A method that passed validation, carrying the resolved handle so the swap phase needs no lookups.
    private struct ValidatedHook {
        let descriptor: MethodHookDescriptor
        let method: Method
    }

    /// Validates every descriptor, then swaps every implementation.
    ///
    /// - Throws: ``MethodHookInstallationFailure`` for the first descriptor that fails validation.
    ///   Nothing has been modified when this throws.
    public static func installAtomically(_ descriptors: [MethodHookDescriptor]) throws {
        let validatedHooks = try descriptors.map(validate)

        for validatedHook in validatedHooks {
            let originalImplementation = method_getImplementation(validatedHook.method)
            let replacementImplementation = validatedHook.descriptor.makeReplacement(originalImplementation)
            method_setImplementation(validatedHook.method, replacementImplementation)
            logger.info("Installed hook \(validatedHook.descriptor.description, privacy: .public)")
        }
    }

    /// Validates a batch without installing anything.
    ///
    /// Useful for a self-check on payload startup that reports host compatibility before any
    /// behaviour changes — for example to decide between hooking and staying dormant.
    public static func validateOnly(_ descriptors: [MethodHookDescriptor]) -> Result<Void, MethodHookInstallationFailure> {
        do {
            _ = try descriptors.map(validate)
            return .success(())
        } catch let failure as MethodHookInstallationFailure {
            return .failure(failure)
        } catch {
            preconditionFailure("validate(_:) only throws MethodHookInstallationFailure")
        }
    }

    private static func validate(_ descriptor: MethodHookDescriptor) throws -> ValidatedHook {
        guard let resolvedClass = objc_getClass(descriptor.className) as? AnyClass else {
            throw MethodHookInstallationFailure.classNotFound(className: descriptor.className)
        }

        let method: Method?
        if descriptor.isInstanceMethod {
            method = class_getInstanceMethod(resolvedClass, descriptor.selector)
        } else {
            method = class_getClassMethod(resolvedClass, descriptor.selector)
        }

        guard let resolvedMethod = method else {
            throw MethodHookInstallationFailure.methodNotFound(
                className: descriptor.className,
                selectorName: NSStringFromSelector(descriptor.selector)
            )
        }

        guard let liveTypeEncodingCString = method_getTypeEncoding(resolvedMethod) else {
            throw MethodHookInstallationFailure.typeEncodingMissing(
                className: descriptor.className,
                selectorName: NSStringFromSelector(descriptor.selector)
            )
        }

        let liveTypeEncoding = String(cString: liveTypeEncodingCString)
        guard typeEncodingsMatch(descriptor.expectedTypeEncoding, liveTypeEncoding) else {
            throw MethodHookInstallationFailure.typeEncodingMismatch(
                className: descriptor.className,
                selectorName: NSStringFromSelector(descriptor.selector),
                expected: descriptor.expectedTypeEncoding,
                actual: liveTypeEncoding
            )
        }

        return ValidatedHook(descriptor: descriptor, method: resolvedMethod)
    }

    private static func typeEncodingsMatch(_ leftEncoding: String, _ rightEncoding: String) -> Bool {
        MethodHookInspector.typeEncodingsMatch(leftEncoding, rightEncoding)
    }
}

/// Reads live type encodings out of the host process.
///
/// Call this from a scratch payload — or from a Swift snippet inside the target under a debugger —
/// to obtain the exact string to paste into a descriptor's `expectedTypeEncoding`, instead of
/// hand-deriving encodings from a decompiler's signature.
public enum MethodHookInspector {
    public static func typeEncoding(
        forClassNamed className: String,
        selector: Selector,
        isInstanceMethod: Bool = true
    ) -> String? {
        guard let resolvedClass = objc_getClass(className) as? AnyClass else { return nil }
        let method = isInstanceMethod
            ? class_getInstanceMethod(resolvedClass, selector)
            : class_getClassMethod(resolvedClass, selector)
        guard let resolvedMethod = method, let encoding = method_getTypeEncoding(resolvedMethod) else { return nil }
        return String(cString: encoding)
    }

    /// Whether the host has this method with the signature the caller is about to assume.
    ///
    /// Calling a host method needs the same signature check that hooking one does. Getting the
    /// signature wrong when *calling* is if anything worse: the arguments are marshalled straight
    /// into the host's registers, and the crash lands in someone else's process with nothing
    /// pointing back here. Check first, and skip the call when the host does not match.
    public static func hasMethod(
        className: String,
        selector: Selector,
        matchingTypeEncoding expectedTypeEncoding: String,
        isInstanceMethod: Bool = true
    ) -> Bool {
        guard let liveTypeEncoding = typeEncoding(
            forClassNamed: className,
            selector: selector,
            isInstanceMethod: isInstanceMethod
        ) else { return false }
        return typeEncodingsMatch(expectedTypeEncoding, liveTypeEncoding)
    }

    /// Compares two type encodings ignoring the frame-offset digits the runtime appends.
    ///
    /// Encodings come in two flavours for the same signature: bare (`v@:@`) and offset-annotated
    /// (`v24@0:8@16`). The offsets are derived from the types, so stripping the digits and comparing
    /// what is left compares exactly the part that matters, and lets an expectation written from one
    /// flavour match a host that reports the other.
    public static func typeEncodingsMatch(_ leftEncoding: String, _ rightEncoding: String) -> Bool {
        stripFrameOffsets(from: leftEncoding) == stripFrameOffsets(from: rightEncoding)
    }

    private static func stripFrameOffsets(from encoding: String) -> String {
        String(encoding.filter { !$0.isNumber })
    }
}
