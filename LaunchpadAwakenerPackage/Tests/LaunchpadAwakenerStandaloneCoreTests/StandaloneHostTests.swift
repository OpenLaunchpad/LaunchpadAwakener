import AppKit
import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
@testable import LaunchpadAwakenerStandaloneCore
import Testing

/// The rules the standalone host follows where the Dock would have answered: the expected values come
/// from macOS's own dynamic wallpaper schedules, from the 27.2 Dock's tables
/// (`/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md` 3.2 and 5.5) and from 15's Dock room.
@Suite("Standalone host")
struct StandaloneHostTests {
    // MARK: - Dynamic wallpapers

    @Test("a light-and-dark wallpaper shows its light picture in the light appearance and its dark one in the dark")
    func appearanceSchedule() {
        let schedule: [String: Any] = ["l": NSNumber(value: 0), "d": NSNumber(value: 1)]
        #expect(StandaloneDynamicWallpaper.imageIndex(forAppearanceSchedule: schedule, isDark: false) == 0)
        #expect(StandaloneDynamicWallpaper.imageIndex(forAppearanceSchedule: schedule, isDark: true) == 1)
    }

    @Test(
        "a time-of-day wallpaper shows the picture of the latest time already past, the night's before dawn",
        arguments: [(0.10, 3), (0.30, 0), (0.55, 1), (0.85, 2), (0.95, 3)]
    )
    func timeSchedule(dayFraction: Double, expectedIndex: Int) {
        // Dawn at 07:12, midday at 12:00, dusk at 19:12, night at 21:36.
        let entries: [[String: Any]] = [
            ["t": NSNumber(value: 0.5), "i": NSNumber(value: 1)],
            ["t": NSNumber(value: 0.3), "i": NSNumber(value: 0)],
            ["t": NSNumber(value: 0.9), "i": NSNumber(value: 3)],
            ["t": NSNumber(value: 0.8), "i": NSNumber(value: 2)],
        ]
        #expect(StandaloneDynamicWallpaper.imageIndex(forTimeEntries: entries, dayFraction: dayFraction) == expectedIndex)
    }

    @Test("six in the morning is a quarter of the way through the day")
    func dayFraction() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let sixInTheMorning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 6)))
        #expect(StandaloneDynamicWallpaper.dayFraction(of: sixInTheMorning, calendar: calendar) == 0.25)
    }

    // MARK: - Icon style

    @Test(
        "each icon appearance theme sets the descriptor as the Dock's table does",
        arguments: [
            // (theme, appearance theme, style, appearance, variant, background)
            (UInt32(1), UInt32(0), UInt8(0), 0, 0, false),
            (UInt32(0), UInt32(1), UInt8(1), 1, 0, false),
            (UInt32(3), UInt32(0), UInt8(2), 0, 3, true),
            (UInt32(5), UInt32(0), UInt8(3), 1, 3, true),
            (UInt32(6), UInt32(0), UInt8(4), 0, 3, true),
            (UInt32(8), UInt32(0), UInt8(5), 1, 2, true),
        ]
    )
    func iconStyleTable(theme: UInt32, appearanceTheme: UInt32, style: UInt8, appearance: Int, variant: Int, drawsBackground: Bool) {
        let configuration = StandaloneIconStyle.Configuration(iconAppearanceTheme: theme, appearanceTheme: appearanceTheme, iconTintColorName: 0, otherIconTintColor: nil)
        let settings = StandaloneIconStyle.descriptorSettings(for: configuration)
        #expect(settings == StandaloneIconStyle.DescriptorSettings(style: style, appearance: appearance, appearanceVariant: variant, drawsBackground: drawsBackground))
    }

    @Test("only the two tinted styles are tinted")
    func tintedStyles() {
        let tintedStyles = (0...8).map { theme in
            StandaloneIconStyle.descriptorSettings(for: .init(iconAppearanceTheme: UInt32(theme), appearanceTheme: 0, iconTintColorName: 0, otherIconTintColor: nil))
        }.filter(\.isTinted).map(\.style)
        #expect(Set(tintedStyles) == [4, 5])
    }

    @Test("named tints and accent colours map to the Dock's system colours: red 0, blue 7, graphite 13")
    func systemColors() {
        #expect(StandaloneIconStyle.systemColor(forTintColorName: 2) == 0)
        #expect(StandaloneIconStyle.systemColor(forTintColorName: 6) == 7)
        #expect(StandaloneIconStyle.systemColor(forTintColorName: 9) == 13)
        #expect(StandaloneIconStyle.systemColor(forTintColorName: 0) == nil)
        #expect(StandaloneIconStyle.systemColor(forAccentColor: 0) == 0)
        #expect(StandaloneIconStyle.systemColor(forAccentColor: 4) == 7)
        #expect(StandaloneIconStyle.systemColor(forAccentColor: -1) == 13)
        #expect(StandaloneIconStyle.systemColor(forAccentColor: nil) == 7)
    }

    // MARK: - The Dock's room and the library

    @Test("a Dock left at its 64-point icons gets the 79 points 15 left it")
    func defaultDockRoom() {
        #expect(SpringboardMetrics.dockThickness(desiredTileSize: 64) == 79)
        #expect(SpringboardMetrics.dockThickness(desiredTileSize: 64) == SpringboardMetrics.defaultDockThickness)
    }

    @Test("the standalone library lives beside the injected one, in a folder of its own")
    func libraryLocation() {
        let databaseURL = StandaloneEnvironment.libraryConfiguration.databaseURL
        #expect(databaseURL.lastPathComponent == "Launchpad.db")
        #expect(databaseURL.deletingLastPathComponent().lastPathComponent == "Standalone")
        #expect(databaseURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "LaunchpadAwakener")
    }

    // MARK: - The Dock's display

    /// A 1512×982 built-in display with a 1366×1024 iPad through Sidecar to its right, in global coordinates
    /// with a top-left origin, as `CGDisplayBounds` gives them.
    private static let builtInAndSidecarDisplays: [(identifier: CGDirectDisplayID, bounds: CGRect)] = [
        (identifier: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
        (identifier: 5, bounds: CGRect(x: 1512, y: 0, width: 1366, height: 1024)),
    ]

    @Test("the Dock is on the display holding the middle of its rectangle")
    func dockOnTheSecondDisplay() {
        let dockRect = CGRect(x: 1700, y: 930, width: 990, height: 94)
        #expect(StandaloneEnvironment.display(holdingDockRect: dockRect, among: Self.builtInAndSidecarDisplays) == 5)
    }

    @Test("a Dock hidden below a display's bottom edge belongs to that display")
    func hiddenDock() {
        let dockRect = CGRect(x: 200, y: 982, width: 1100, height: 94)
        #expect(StandaloneEnvironment.display(holdingDockRect: dockRect, among: Self.builtInAndSidecarDisplays) == 1)
    }

    @Test("a rectangle far from every display belongs to none")
    func rectangleOffEveryDisplay() {
        let dockRect = CGRect(x: 10_000, y: 10_000, width: 990, height: 94)
        #expect(StandaloneEnvironment.display(holdingDockRect: dockRect, among: Self.builtInAndSidecarDisplays) == nil)
    }

    /// The window server of the machine the tests run on, asked as the standalone app asks it.
    @Test(
        "the window server's Dock rectangle lies on one of this machine's displays",
        .enabled(if: CGMainDisplayID() != kCGNullDirectDisplay)
    )
    func dockDisplayOfThisMachine() throws {
        let dockRect = try #require(SkyLightBridge.dockRect)
        let dockDisplay = try #require(StandaloneEnvironment.dockDisplayIdentifier, "the Dock's rectangle \(dockRect) is on no display")
        #expect(SpringboardDisplay.activeDisplays.contains(dockDisplay))
    }

    /// Pins the rectangle's coordinate space on a real system: turned from a top-left origin into AppKit's
    /// bottom-left one, a Dock at the bottom that stays on screen ends where AppKit's visible frame of its
    /// screen starts. A single display cannot tell the two origins apart by which display holds the Dock.
    @Test(
        "the window server's Dock rectangle has a top-left origin",
        .enabled(if: Self.hasBottomDockThatStaysOnScreen)
    )
    @MainActor
    func dockRectangleOrigin() throws {
        let dockRect = try #require(SkyLightBridge.dockRect)
        let zeroScreenHeight = try #require(NSScreen.screens.first).frame.height
        let dockRectFromBottomLeft = CGRect(x: dockRect.minX, y: zeroScreenHeight - dockRect.maxY, width: dockRect.width, height: dockRect.height)
        let dockScreen = try #require(NSScreen.screens.first { screen in
            screen.frame.contains(CGPoint(x: dockRectFromBottomLeft.midX, y: dockRectFromBottomLeft.midY))
        })
        #expect(
            abs(dockScreen.visibleFrame.minY - dockRectFromBottomLeft.maxY) <= 1,
            "visible frame \(NSStringFromRect(dockScreen.visibleFrame)), the Dock from the bottom left \(NSStringFromRect(dockRectFromBottomLeft))"
        )
    }

    private static var hasBottomDockThatStaysOnScreen: Bool {
        let dockPreferences = UserDefaults(suiteName: "com.apple.dock")
        let orientation = dockPreferences?.string(forKey: "orientation") ?? "bottom"
        return orientation == "bottom" && dockPreferences?.bool(forKey: "autohide") == false && CGMainDisplayID() != kCGNullDirectDisplay
    }
}
