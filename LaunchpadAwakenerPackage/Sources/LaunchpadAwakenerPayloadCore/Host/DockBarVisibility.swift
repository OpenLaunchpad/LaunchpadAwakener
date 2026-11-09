import Foundation
import ObjCRuntimeToolbox
import ObjectiveC
import OSToolbox
import LaunchpadAwakenerSpringboardCore

/// The calls made on the Dock's `DockVisibility`, behind a protocol so that their pairing can be tested
/// without the Dock.
@MainActor
protocol DockVisibilityCalls: AnyObject {
    func setOverrideShowType(_ showType: UInt64)
    func removeOverrideShowType(_ showType: UInt64)
    func forceDockHidden(reason: String)
    func removeForceDockHidden(reason: String)
    /// Whether the Dock still holds `reason`. Letting go of a reason it does not hold raises.
    func holdsForceHiddenReason(_ reason: String) -> Bool
}

/// Keeps the Dock on screen while the springboard shows and slides it away while a folder is open, through
/// the Dock's own `DockVisibility`, as macOS 15's Launchpad did; see ``SpringboardDockVisibility``.
///
/// Hiding borrows the Dock's auto-hide: `forceDockHiddenWithReason:` turns auto-hide on in memory and
/// starts the Dock's own slide, 0.24 s at the default size. Nothing is written to the preferences and the
/// screen's usable area does not change (15.5 `0x100054E3C`, 27.2 `0x100035240`; the call path and the
/// timing are in `/Volumes/RE/Dock/27.2/Notes/DockVisibilityAndFloor.md`). The Dock keeps the reasons in a
/// dictionary and raises when asked to let go of one it does not hold, which crashes it; so each hold is let
/// go exactly once, on the object that took it, and only while the Dock still has it.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockBarVisibility")
@MainActor
final class DockBarVisibility {
    static let shared = DockBarVisibility { LiveDockVisibility.current }

    /// The show override bit 15's Launchpad used. 27.2's Dock uses 8, 0x10, 0x20 and 0x40 for other things
    /// and nothing uses 1.
    static let showOverrideType: UInt64 = 1
    /// The springboard's own reason, so that it never lets go of a hold anything else in the Dock took.
    static let forceHiddenReason = "LaunchpadAwakener-ShowGroup"

    private let resolveController: @MainActor () -> (any DockVisibilityCalls)?
    /// The controller the show override was set on, until it is removed.
    private var overriddenController: (any DockVisibilityCalls)?
    /// The controller asked to hide the Dock, until it is let go.
    private var forcedController: (any DockVisibilityCalls)?

    init(resolveController: @escaping @MainActor () -> (any DockVisibilityCalls)?) {
        self.resolveController = resolveController
    }

    /// Whether the show override is set.
    var isHoldingDockShown: Bool {
        overriddenController != nil
    }

    /// Whether the Dock was asked to hide and has not been let go.
    var isHoldingDockHidden: Bool {
        forcedController != nil
    }

    func apply(_ visibility: SpringboardDockVisibility) {
        let wantsShown = visibility != .unchanged
        let wantsHidden = visibility == .hidden
        // Let go in the reverse order of taking hold: the folder's hold first, then the override.
        if !wantsHidden, let forcedController {
            self.forcedController = nil
            if forcedController.holdsForceHiddenReason(Self.forceHiddenReason) {
                forcedController.removeForceDockHidden(reason: Self.forceHiddenReason)
                #log(.info, "Let the Dock come back")
            } else {
                #log(.error, "The Dock no longer holds \(Self.forceHiddenReason, privacy: .public); not letting go of it, which would raise")
            }
        }
        if !wantsShown, let overriddenController {
            self.overriddenController = nil
            overriddenController.removeOverrideShowType(Self.showOverrideType)
            #log(.info, "Gave the Dock back its own visibility")
        }
        if wantsShown, overriddenController == nil, let controller = resolveController() {
            controller.setOverrideShowType(Self.showOverrideType)
            overriddenController = controller
            #log(.info, "Keeping the Dock on screen")
        }
        if wantsHidden, forcedController == nil, let controller = resolveController() {
            controller.forceDockHidden(reason: Self.forceHiddenReason)
            forcedController = controller
            #log(.info, "Sliding the Dock away for an open folder")
        }
    }
}

/// The Dock's `DockVisibility`, reached through `-[DockBar visibilityController]`.
///
/// Every method used, and the ivar holding the reasons, are checked on the object's own class each time it
/// is looked up. When any of them is missing or changed, there is no controller and the Dock is left alone.
/// The signatures are the same from 26.0 to 27.2, and in 15.5.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "LiveDockVisibility")
@MainActor
final class LiveDockVisibility: DockVisibilityCalls {
    // MARK: - Signatures

    nonisolated static let visibilityControllerSignature = DockMethodSignature(className: "DockBar", selectorName: "visibilityController", typeEncoding: "@16@0:8")
    nonisolated static let setOverrideShowTypeSignature = DockMethodSignature(
        className: "DockVisibility",
        selectorName: "setOverrideShowType:",
        typeEncoding: "v24@0:8Q16"
    )
    nonisolated static let removeOverrideShowTypeSignature = DockMethodSignature(
        className: "DockVisibility",
        selectorName: "removeOverrideShowType:",
        typeEncoding: "v24@0:8Q16"
    )
    nonisolated static let forceDockHiddenSignature = DockMethodSignature(
        className: "DockVisibility",
        selectorName: "forceDockHiddenWithReason:",
        typeEncoding: "v24@0:8@16"
    )
    nonisolated static let removeForceDockHiddenSignature = DockMethodSignature(
        className: "DockVisibility",
        selectorName: "removeForceDockHiddenWithReason:",
        typeEncoding: "v24@0:8@16"
    )
    /// `NSMutableDictionary *_dockForceHiddenReasons`, a count for each reason.
    nonisolated static let forceHiddenReasonsIvarName = "_dockForceHiddenReasons"
    nonisolated static let forceHiddenReasonsIvarTypeEncoding = "@\"NSMutableDictionary\""

    private nonisolated static let controllerMethods = [
        setOverrideShowTypeSignature,
        removeOverrideShowTypeSignature,
        forceDockHiddenSignature,
        removeForceDockHiddenSignature,
    ]

    /// What the running Dock lacks of the methods and the ivar used here, checked by class: empty when
    /// everything matches. Logged once as the payload starts, so a Dock update can be read off the log.
    nonisolated static func missingMembers() -> [String] {
        var missingMembers = ([visibilityControllerSignature] + controllerMethods).compactMap { signature -> String? in
            RuntimeMethodInspector.hasMethod(className: signature.className, selector: signature.selector, matchingTypeEncoding: signature.typeEncoding)
                ? nil
                : "-[\(signature.className) \(signature.selectorName)]"
        }
        if forceHiddenReasonsIvar(of: NSClassFromString(forceDockHiddenSignature.className)) == nil {
            missingMembers.append("\(forceDockHiddenSignature.className).\(forceHiddenReasonsIvarName)")
        }
        return missingMembers
    }

    /// The ivar holding the reasons, when `controllerClass` has it with the expected type.
    private nonisolated static func forceHiddenReasonsIvar(of controllerClass: AnyClass?) -> Ivar? {
        guard
            let controllerClass,
            let ivar = class_getInstanceVariable(controllerClass, forceHiddenReasonsIvarName),
            let ivarTypeEncoding = ivar_getTypeEncoding(ivar),
            String(cString: ivarTypeEncoding) == forceHiddenReasonsIvarTypeEncoding
        else { return nil }
        return ivar
    }

    private weak var controller: NSObject?
    private let forceHiddenReasonsIvar: Ivar

    private init(controller: NSObject, forceHiddenReasonsIvar: Ivar) {
        self.controller = controller
        self.forceHiddenReasonsIvar = forceHiddenReasonsIvar
    }

    /// The Dock's visibility controller as it is now; nil when it is out of reach or does not match.
    static var current: LiveDockVisibility? {
        guard
            let dockBar = DockBarReference.dockBar,
            let controller = DockEnvironment.checkedObjectValue(of: dockBar, selector: visibilityControllerSignature.selector)
        else {
            #log(.error, "The Dock's visibility controller is out of reach; the Dock stays as it is")
            return nil
        }
        let matchesEveryMethod = controllerMethods.allSatisfy { signature in
            DockEnvironment.hasMethod(controller, selector: signature.selector, typeEncoding: signature.typeEncoding)
        }
        guard matchesEveryMethod else { return nil }
        guard let ivar = forceHiddenReasonsIvar(of: object_getClass(controller)) else {
            #log(.error, "-[\(String(cString: object_getClassName(controller)), privacy: .public) \(forceHiddenReasonsIvarName, privacy: .public)] is missing or changed; the Dock stays as it is")
            return nil
        }
        return LiveDockVisibility(controller: controller, forceHiddenReasonsIvar: ivar)
    }

    // MARK: - Calls

    func setOverrideShowType(_ showType: UInt64) {
        callShowType(Self.setOverrideShowTypeSignature.selector, showType)
    }

    func removeOverrideShowType(_ showType: UInt64) {
        callShowType(Self.removeOverrideShowTypeSignature.selector, showType)
    }

    func forceDockHidden(reason: String) {
        callReason(Self.forceDockHiddenSignature.selector, reason)
    }

    func removeForceDockHidden(reason: String) {
        callReason(Self.removeForceDockHiddenSignature.selector, reason)
    }

    func holdsForceHiddenReason(_ reason: String) -> Bool {
        guard let controller, let reasons = object_getIvar(controller, forceHiddenReasonsIvar) as? NSDictionary else { return false }
        return reasons[reason] != nil
    }

    /// Calls a method taking an `unsigned long long`, whose signature was checked when this was made.
    private func callShowType(_ selector: Selector, _ showType: UInt64) {
        guard let controller else { return }
        typealias ShowTypeFunction = @convention(c) (AnyObject, Selector, UInt64) -> Void
        let implementation = unsafeBitCast(controller.method(for: selector), to: ShowTypeFunction.self)
        implementation(controller, selector, showType)
    }

    /// Calls a method taking an object, whose signature was checked when this was made.
    private func callReason(_ selector: Selector, _ reason: String) {
        guard let controller else { return }
        typealias ReasonFunction = @convention(c) (AnyObject, Selector, NSString) -> Void
        let implementation = unsafeBitCast(controller.method(for: selector), to: ReasonFunction.self)
        implementation(controller, selector, reason as NSString)
    }
}
