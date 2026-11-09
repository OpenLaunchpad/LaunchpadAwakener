import AppKit
import LaunchpadAwakenerPrivateInterfaces
import LaunchpadAwakenerSpringboardCore
import OSToolbox

/// The icon style the Dock would draw its tiles in, worked out without the Dock: SkyLight's icon
/// appearance configuration, turned into an `ISImageDescriptor` by the Dock's own table
/// (`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md` 3.2, 3.3 "way B" and 5.5). SkyLight, IconServices and
/// IconFoundation export the classes used, so they are declared in `LaunchpadAwakenerPrivateInterfaces`
/// and called directly.
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
        guard let configuration = SLSIconAppearanceConfiguration.fetchCurrentIconAppearanceConfiguration() else {
            #log(.error, "SkyLight has no icon appearance configuration; icons use the default style")
            return nil
        }
        return Configuration(
            iconAppearanceTheme: configuration.iconAppearanceTheme,
            appearanceTheme: configuration.appearanceTheme,
            iconTintColorName: configuration.iconTintColorName,
            otherIconTintColor: configuration.otherIconTintColor
        )
    }

    // MARK: - IconServices

    private static func makeDescriptor(settings: DescriptorSettings, configuration: Configuration) -> NSObject? {
        let descriptor = ISImageDescriptor()
        descriptor.appearance = settings.appearance
        descriptor.appearanceVariant = settings.appearanceVariant
        if settings.drawsBackground {
            descriptor.background = 1
        }
        if settings.isTinted {
            descriptor.tintColor = makeTintColor(configuration: configuration, isDark: settings.appearance == 1)
        }
        return descriptor
    }

    /// The `IFColor` the Dock tints with: a named tint, the custom one, or the accent colour.
    private static func makeTintColor(configuration: Configuration, isDark: Bool) -> IFColor? {
        if configuration.iconTintColorName == 10, let otherIconTintColor = configuration.otherIconTintColor {
            return IFColor(cgColor: otherIconTintColor)
        }
        let systemColor = systemColor(forTintColorName: configuration.iconTintColorName)
            ?? systemColor(forAccentColor: UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int)
        return IFColor(systemColor: systemColor, appearance: isDark ? 1 : 0, contrast: 0, vibrancy: 0)
    }
}
