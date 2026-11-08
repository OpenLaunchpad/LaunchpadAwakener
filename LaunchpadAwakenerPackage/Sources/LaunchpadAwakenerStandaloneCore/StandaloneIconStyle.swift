import AppKit
import LaunchpadAwakenerHookKit
import LaunchpadAwakenerSpringboardCore
import ObjectiveC
import OSToolbox

/// The icon style the Dock would draw its tiles in, worked out without the Dock: SkyLight's icon
/// appearance configuration, turned into an `ISImageDescriptor` by the Dock's own table
/// (`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md` 3.2, 3.3 "way B" and 5.5). Every private call is
/// checked against its type encoding first; when one does not match, icons keep the default style.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "StandaloneIconStyle")
@MainActor
enum StandaloneIconStyle {
    /// What the configuration holds, read once per showing.
    struct Configuration: Equatable {
        /// 0 automatic, 1 light, 2 dark; 3 automatic clear, 4 and 5 clear light and dark; 6 automatic tinted, 7 and 8 tinted.
        var iconAppearanceTheme: UInt32
        /// Non-zero is dark.
        var appearanceTheme: UInt32
        /// 0 follows the accent colour, 1 the hardware one, 2…9 red to graphite, 10 ``otherIconTintColor``.
        var iconTintColorName: UInt32
        var otherIconTintColor: CGColor?
    }

    /// How a style sets up the descriptor: `appearance`, `appearanceVariant`, and whether it draws a background.
    struct DescriptorSettings: Equatable {
        let style: UInt8
        let appearance: Int
        let appearanceVariant: Int
        let drawsBackground: Bool
        var isTinted: Bool {
            style == 4 || style == 5
        }
    }

    static var current: SpringboardIconStyle? {
        guard let configuration = fetchConfiguration() else { return nil }
        let settings = descriptorSettings(for: configuration)
        guard let descriptor = makeDescriptor(settings: settings, configuration: configuration) else { return nil }
        return SpringboardIconStyle(iconDescriptor: descriptor, style: settings.style)
    }

    /// `IconAppearanceTheme_ToIconStyle` (27.2 `0x100169F48`) and the descriptor tables at `0x100262A88` and
    /// `0x100262AB0`: the automatic themes pick light or dark from the appearance.
    nonisolated static func descriptorSettings(for configuration: Configuration) -> DescriptorSettings {
        let isDark = configuration.appearanceTheme != 0
        let style: UInt8 = switch configuration.iconAppearanceTheme {
        case 1: 0
        case 2: 1
        case 0: isDark ? 1 : 0
        case 4: 2
        case 5: 3
        case 3: isDark ? 3 : 2
        case 7: 4
        case 8: 5
        case 6: isDark ? 5 : 4
        default: 0
        }
        return switch style {
        case 1: DescriptorSettings(style: 1, appearance: 1, appearanceVariant: 0, drawsBackground: false)
        case 2: DescriptorSettings(style: 2, appearance: 0, appearanceVariant: 3, drawsBackground: true)
        case 3: DescriptorSettings(style: 3, appearance: 1, appearanceVariant: 3, drawsBackground: true)
        case 4: DescriptorSettings(style: 4, appearance: 0, appearanceVariant: 3, drawsBackground: true)
        case 5: DescriptorSettings(style: 5, appearance: 1, appearanceVariant: 2, drawsBackground: true)
        default: DescriptorSettings(style: 0, appearance: 0, appearanceVariant: 0, drawsBackground: false)
        }
    }

    /// The `IFColor` system colour of a named tint, 2…9 (`sub_100169FCC`'s table); nil for the others.
    nonisolated static func systemColor(forTintColorName tintColorName: UInt32) -> Int? {
        let systemColors = [0, 1, 2, 3, 7, 9, 10, 13]
        let tableIndex = Int(tintColorName) - 2
        return systemColors.indices.contains(tableIndex) ? systemColors[tableIndex] : nil
    }

    /// The system colour of the user's accent colour, `AppleAccentColor`: −1 graphite, 0…6 red, orange,
    /// yellow, green, blue, purple, pink; anything else — multicolour, or the hardware colour this does
    /// not look up — the system blue (`SystemAccentColorMonitor`).
    nonisolated static func systemColor(forAccentColor accentColor: Int?) -> Int {
        switch accentColor {
        case -1: 13
        case 0: 0
        case 1: 1
        case 2: 2
        case 3: 3
        case 4: 7
        case 5: 9
        case 6: 10
        default: 7
        }
    }

    // MARK: - SkyLight

    private static func fetchConfiguration() -> Configuration? {
        let configurationClassName = "SLSIconAppearanceConfiguration"
        guard
            MethodHookInspector.hasMethod(className: configurationClassName, selector: NSSelectorFromString("fetchCurrentIconAppearanceConfiguration"), matchingTypeEncoding: "@16@0:8", isInstanceMethod: false),
            let configurationClass = NSClassFromString(configurationClassName) as? NSObject.Type,
            let configuration = configurationClass.perform(NSSelectorFromString("fetchCurrentIconAppearanceConfiguration"))?.takeUnretainedValue() as? NSObject
        else {
            #log(.error, "SkyLight's icon appearance configuration is out of reach; icons use the default style")
            return nil
        }
        guard
            let iconAppearanceTheme = unsignedValue(of: configuration, selectorName: "iconAppearanceTheme"),
            let appearanceTheme = unsignedValue(of: configuration, selectorName: "appearanceTheme"),
            let iconTintColorName = unsignedValue(of: configuration, selectorName: "iconTintColorName")
        else { return nil }
        return Configuration(
            iconAppearanceTheme: iconAppearanceTheme,
            appearanceTheme: appearanceTheme,
            iconTintColorName: iconTintColorName,
            otherIconTintColor: colorValue(of: configuration, selectorName: "otherIconTintColor")
        )
    }

    // MARK: - IconServices

    private static func makeDescriptor(settings: DescriptorSettings, configuration: Configuration) -> NSObject? {
        guard let descriptorClass = NSClassFromString("ISImageDescriptor") as? NSObject.Type else { return nil }
        let descriptor = descriptorClass.init()
        guard
            setInteger(settings.appearance, on: descriptor, selectorName: "setAppearance:", typeEncoding: "v24@0:8q16"),
            setInteger(settings.appearanceVariant, on: descriptor, selectorName: "setAppearanceVariant:", typeEncoding: "v24@0:8q16")
        else {
            #log(.error, "ISImageDescriptor's appearance setters are missing or changed; icons use the default style")
            return nil
        }
        if settings.drawsBackground {
            _ = setInteger(1, on: descriptor, selectorName: "setBackground:", typeEncoding: "v24@0:8Q16")
        }
        if settings.isTinted, let tintColor = makeTintColor(configuration: configuration, isDark: settings.appearance == 1) {
            let setTintColorSelector = NSSelectorFromString("setTintColor:")
            if hasMethod(descriptor, setTintColorSelector, typeEncoding: "v24@0:8@16") {
                descriptor.perform(setTintColorSelector, with: tintColor)
            }
        }
        return descriptor
    }

    /// The `IFColor` the Dock tints with: a named tint, the custom one, or the accent colour.
    private static func makeTintColor(configuration: Configuration, isDark: Bool) -> NSObject? {
        if configuration.iconTintColorName == 10, let otherIconTintColor = configuration.otherIconTintColor {
            return makeColor(wrapping: otherIconTintColor)
        }
        let systemColor = systemColor(forTintColorName: configuration.iconTintColorName)
            ?? systemColor(forAccentColor: UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int)
        return makeColor(systemColor: systemColor, isDark: isDark)
    }

    /// `-[IFColor initWithSystemColor:appearance:contrast:vibrancy:]`.
    private static func makeColor(systemColor: Int, isDark: Bool) -> NSObject? {
        let selector = NSSelectorFromString("initWithSystemColor:appearance:contrast:vibrancy:")
        guard
            MethodHookInspector.hasMethod(className: "IFColor", selector: selector, matchingTypeEncoding: "@48@0:8q16q24q32q40", isInstanceMethod: true),
            let colorClass = NSClassFromString("IFColor") as? NSObject.Type,
            let initialiserImplementation = class_getMethodImplementation(colorClass, selector),
            let allocatedColor = colorClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { return nil }
        typealias InitialiserFunction = @convention(c) (AnyObject, Selector, Int, Int, Int, Int) -> Unmanaged<NSObject>?
        // The initialiser consumes the allocated reference and returns +1.
        return unsafeBitCast(initialiserImplementation, to: InitialiserFunction.self)(allocatedColor, selector, systemColor, isDark ? 1 : 0, 0, 0)?.takeRetainedValue()
    }

    /// `-[IFColor initWithCGColor:]`.
    private static func makeColor(wrapping color: CGColor) -> NSObject? {
        let selector = NSSelectorFromString("initWithCGColor:")
        guard
            MethodHookInspector.hasMethod(className: "IFColor", selector: selector, matchingTypeEncoding: "@24@0:8^{CGColor=}16", isInstanceMethod: true),
            let colorClass = NSClassFromString("IFColor") as? NSObject.Type,
            let initialiserImplementation = class_getMethodImplementation(colorClass, selector),
            let allocatedColor = colorClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { return nil }
        typealias InitialiserFunction = @convention(c) (AnyObject, Selector, CGColor) -> Unmanaged<NSObject>?
        return unsafeBitCast(initialiserImplementation, to: InitialiserFunction.self)(allocatedColor, selector, color)?.takeRetainedValue()
    }

    // MARK: - Checked calls

    private static func hasMethod(_ object: NSObject, _ selector: Selector, typeEncoding expectedTypeEncoding: String) -> Bool {
        guard
            let method = class_getInstanceMethod(object_getClass(object), selector),
            let typeEncoding = method_getTypeEncoding(method)
        else { return false }
        return MethodHookInspector.typeEncodingsMatch(String(cString: typeEncoding), expectedTypeEncoding)
    }

    private static func unsignedValue(of object: NSObject, selectorName: String) -> UInt32? {
        let selector = NSSelectorFromString(selectorName)
        guard hasMethod(object, selector, typeEncoding: "I16@0:8") else {
            #log(.error, "-[\(String(cString: object_getClassName(object)), privacy: .public) \(selectorName, privacy: .public)] is missing or changed")
            return nil
        }
        typealias UnsignedFunction = @convention(c) (AnyObject, Selector) -> UInt32
        return unsafeBitCast(object.method(for: selector), to: UnsignedFunction.self)(object, selector)
    }

    private static func colorValue(of object: NSObject, selectorName: String) -> CGColor? {
        let selector = NSSelectorFromString(selectorName)
        guard hasMethod(object, selector, typeEncoding: "^{CGColor=}16@0:8") else { return nil }
        typealias ColorFunction = @convention(c) (AnyObject, Selector) -> Unmanaged<CGColor>?
        return unsafeBitCast(object.method(for: selector), to: ColorFunction.self)(object, selector)?.takeUnretainedValue()
    }

    private static func setInteger(_ value: Int, on object: NSObject, selectorName: String, typeEncoding: String) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard hasMethod(object, selector, typeEncoding: typeEncoding) else { return false }
        typealias SetIntegerFunction = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(object.method(for: selector), to: SetIntegerFunction.self)(object, selector, value)
        return true
    }
}
