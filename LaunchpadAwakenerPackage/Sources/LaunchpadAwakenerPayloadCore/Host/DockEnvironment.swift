import CoreGraphics
import Foundation
import LaunchpadAwakenerHookKit
import ObjectiveC
import OSToolbox

/// What the springboard needs to know about the Dock and its display, read from the Dock itself.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockEnvironment")
@MainActor
enum DockEnvironment {
    // MARK: - Signatures

    nonisolated static let dockBarDisplay = DockMethodSignature(className: "DockBar", selectorName: "display", typeEncoding: "@16@0:8")
    nonisolated static let dockBarEnvironment = DockMethodSignature(className: "DockBar", selectorName: "environment", typeEncoding: "@16@0:8")
    nonisolated static let displayNotchBounds = DockMethodSignature(
        className: "DisplayDescriptor",
        selectorName: "notchBounds",
        typeEncoding: "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8"
    )

    nonisolated static let requiredMethods: [DockMethodSignature] = [dockBarDisplay, dockBarEnvironment, displayNotchBounds]

    /// Swift classes reached through the environment; checked on the object actually returned, and
    /// optional: without them icons fall back to the default style.
    private static let iconAppearanceMonitorSelector = NSSelectorFromString("iconAppearanceMonitor")
    private static let appearanceSelector = NSSelectorFromString("appearance")
    private static let iconDescriptionSelector = NSSelectorFromString("iconDescription")
    private static let styleSelector = NSSelectorFromString("style")

    // MARK: - Geometry

    /// The Dock's preference; the bar itself does not expose it.
    static var dockOrientation: DockOrientation {
        UserDefaults.standard.string(forKey: "orientation").flatMap(DockOrientation.init(rawValue:)) ?? .bottom
    }

    /// How far the Dock reaches into the screen: the height of the bar, or its width at the sides.
    /// macOS 15 measured its tiles; macOS 27's bar adds the glass around them, and keeping 15's gap above
    /// that keeps the grid clear of it.
    static var dockThickness: CGFloat {
        guard let barRect = DockBarReference.currentBarRect, !barRect.isEmpty else { return 70 }
        return dockOrientation == .bottom ? barRect.height : barRect.width
    }

    /// The camera housing's height on the Dock's display; zero without one.
    static var notchHeight: CGFloat {
        guard
            let dockBar = DockBarReference.dockBar,
            let display = objectValue(of: dockBar, selector: dockBarDisplay.selector),
            MethodHookInspector.typeEncodingsMatch(typeEncoding(of: display, selector: displayNotchBounds.selector) ?? "", displayNotchBounds.typeEncoding)
        else { return 0 }
        typealias RectFunction = @convention(c) (AnyObject, Selector) -> CGRect
        let implementation = unsafeBitCast(display.method(for: displayNotchBounds.selector), to: RectFunction.self)
        return implementation(display, displayNotchBounds.selector).height
    }

    // MARK: - Icon appearance

    /// The icon style the Dock draws its own tiles in, as `IconAppearance` holds it.
    struct IconAppearance {
        /// An `ISImageDescriptor` set up for the current style; copy before changing it.
        let iconDescriptor: NSObject
        /// `IconStyle`: 0 and 1 default, 2 and 3 clear, 4 and 5 tinted (light and dark each).
        let style: UInt8

        /// The compositing filter the Dock gives its tile images in this style
        /// (`IconStyle_GlassCompositingFilter`, 27.2 `0x10016AC54`).
        var glassCompositingFilterName: String? {
            switch style {
            case 2, 3, 4: QuartzCorePrivate.stringConstant(named: "kCAFilterClearIconBlendMode")
            case 5: QuartzCorePrivate.stringConstant(named: "kCAFilterScreenBlendMode")
            default: nil
            }
        }
    }

    /// `DockBar.environment.iconAppearanceMonitor.appearance`; nil when any step is missing.
    static var iconAppearance: IconAppearance? {
        guard
            let dockBar = DockBarReference.dockBar,
            let environment = objectValue(of: dockBar, selector: dockBarEnvironment.selector),
            let monitor = checkedObjectValue(of: environment, selector: iconAppearanceMonitorSelector),
            let appearance = checkedObjectValue(of: monitor, selector: appearanceSelector),
            let iconDescriptor = checkedObjectValue(of: appearance, selector: iconDescriptionSelector),
            typeEncoding(of: appearance, selector: styleSelector).map({ MethodHookInspector.typeEncodingsMatch($0, "C16@0:8") }) == true
        else {
            #log(.error, "The Dock's icon appearance is out of reach; icons use the default style")
            return nil
        }
        typealias StyleFunction = @convention(c) (AnyObject, Selector) -> UInt8
        let styleImplementation = unsafeBitCast(appearance.method(for: styleSelector), to: StyleFunction.self)
        return IconAppearance(iconDescriptor: iconDescriptor, style: styleImplementation(appearance, styleSelector))
    }

    // MARK: - Calls

    private static func typeEncoding(of object: NSObject, selector: Selector) -> String? {
        guard let method = class_getInstanceMethod(object_getClass(object), selector), let encoding = method_getTypeEncoding(method) else { return nil }
        return String(cString: encoding)
    }

    /// Calls an object-returning, argument-less method whose signature is already known to match.
    private static func objectValue(of receiver: NSObject, selector: Selector) -> NSObject? {
        typealias ObjectFunction = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let implementation = unsafeBitCast(receiver.method(for: selector), to: ObjectFunction.self)
        return implementation(receiver, selector)?.takeUnretainedValue() as? NSObject
    }

    /// Same, after checking on the receiver's own class that the method takes nothing and returns an object.
    private static func checkedObjectValue(of receiver: NSObject, selector: Selector) -> NSObject? {
        guard let encoding = typeEncoding(of: receiver, selector: selector), MethodHookInspector.typeEncodingsMatch(encoding, "@16@0:8") else {
            #log(.error, "-[\(String(cString: object_getClassName(receiver)), privacy: .public) \(NSStringFromSelector(selector), privacy: .public)] is missing or changed")
            return nil
        }
        return objectValue(of: receiver, selector: selector)
    }
}
