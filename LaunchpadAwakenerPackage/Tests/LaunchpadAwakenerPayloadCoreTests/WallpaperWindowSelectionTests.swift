import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerPayloadCore
import Testing

/// Which window the springboard takes its wallpaper from.
///
/// The window numbers, owners, levels, bounds and names are the windows below the normal level that
/// `CGWindowListCopyWindowInfo` returned on 2026-11-08 on the macOS 26.6.2 virtual machine and on the
/// macOS 27.2 test MacBook, both set to Simplified Chinese — which is why the Dock's own window is owned
/// by 「程序坞」. Only the virtual machine's Dock and the MacBook's WindowManager had their process
/// identifiers recorded; the others are made up. The macOS 26 list leaves out two of the notification
/// centre's three windows.
@Suite("Wallpaper window selection")
struct WallpaperWindowSelectionTests {
    private static let desktopIconWindowLevel = -2147483603

    private static func windowDescription(
        number: CGWindowID,
        ownerName: String,
        ownerProcessIdentifier: pid_t,
        level: Int,
        bounds: CGRect,
        name: String? = nil
    ) -> [String: Any] {
        var description: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: number),
            kCGWindowOwnerName as String: ownerName,
            kCGWindowOwnerPID as String: NSNumber(value: ownerProcessIdentifier),
            kCGWindowLayer as String: NSNumber(value: level),
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary,
        ]
        if let name {
            description[kCGWindowName as String] = name
        }
        return description
    }

    // MARK: - macOS 26.6.2, the virtual machine

    private static let macOS26DisplayBounds = CGRect(x: 0, y: 0, width: 1491, height: 902)
    private static let macOS26DockProcessIdentifier: pid_t = 443

    private static var macOS26Windows: [[String: Any]] { [
        windowDescription(number: 39, ownerName: "通知中心", ownerProcessIdentifier: 612, level: -2147483601, bounds: CGRect(x: 8, y: 218, width: 360, height: 180)),
        windowDescription(number: 34, ownerName: "Window Server", ownerProcessIdentifier: 152, level: -2147483602, bounds: CGRect(x: 0, y: 0, width: 1491, height: 76)),
        // The desktop icons: the whole display, but at the desktop icon level itself.
        windowDescription(number: 14, ownerName: "访达", ownerProcessIdentifier: 455, level: -2147483603, bounds: macOS26DisplayBounds),
        windowDescription(number: 12, ownerName: "程序坞", ownerProcessIdentifier: macOS26DockProcessIdentifier, level: -2147483624, bounds: macOS26DisplayBounds, name: "Wallpaper-"),
        // The backstop: the whole display, below the desktop icons, but nobody's wallpaper.
        windowDescription(number: 2, ownerName: "Window Server", ownerProcessIdentifier: 152, level: -2147483626, bounds: macOS26DisplayBounds),
    ] }

    @Test("on macOS 26 the wallpaper is the Dock's own window")
    func macOS26TakesTheDocksWindow() {
        let windowNumber = WallpaperSnapshot.wallpaperWindowNumber(
            in: Self.macOS26Windows,
            displayBounds: Self.macOS26DisplayBounds,
            desktopIconWindowLevel: Self.desktopIconWindowLevel,
            dockProcessIdentifier: Self.macOS26DockProcessIdentifier,
            isWindowManagerProcess: { _ in false }
        )
        #expect(windowNumber == 12)
    }

    // MARK: - macOS 27.2, the test MacBook

    private static let macOS27DisplayBounds = CGRect(x: 0, y: 0, width: 1739, height: 1080)
    private static let macOS27DockProcessIdentifier: pid_t = 470
    private static let macOS27WindowManagerProcessIdentifier: pid_t = 474

    private static var macOS27Windows: [[String: Any]] { [
        windowDescription(number: 19, ownerName: "WindowManager", ownerProcessIdentifier: macOS27WindowManagerProcessIdentifier, level: -2147483624, bounds: macOS27DisplayBounds, name: "Wallpaper"),
        // The wallpaper agent's copy, never on screen as the desktop.
        windowDescription(number: 7873, ownerName: "墙纸", ownerProcessIdentifier: 487, level: -2147483625, bounds: macOS27DisplayBounds, name: "Offscreen Wallpaper Window"),
        windowDescription(number: 229, ownerName: "Window Server", ownerProcessIdentifier: 175, level: -2147483626, bounds: macOS27DisplayBounds, name: "Display 6 Backstop"),
    ] }

    @Test("on macOS 27 the wallpaper is WindowManager's window")
    func macOS27TakesWindowManagersWindow() {
        let windowNumber = WallpaperSnapshot.wallpaperWindowNumber(
            in: Self.macOS27Windows,
            displayBounds: Self.macOS27DisplayBounds,
            desktopIconWindowLevel: Self.desktopIconWindowLevel,
            dockProcessIdentifier: Self.macOS27DockProcessIdentifier,
            isWindowManagerProcess: { $0 == Self.macOS27WindowManagerProcessIdentifier }
        )
        #expect(windowNumber == 19)
    }

    @Test("WindowManager is told apart by process, not by its owner name")
    func windowManagerIsFoundUnderAnotherName() {
        let renamedWindows = Self.macOS27Windows.map { windowDescription in
            var renamedDescription = windowDescription
            renamedDescription[kCGWindowOwnerName as String] = "窗口管理器"
            return renamedDescription
        }
        let windowNumber = WallpaperSnapshot.wallpaperWindowNumber(
            in: renamedWindows,
            displayBounds: Self.macOS27DisplayBounds,
            desktopIconWindowLevel: Self.desktopIconWindowLevel,
            dockProcessIdentifier: Self.macOS27DockProcessIdentifier,
            isWindowManagerProcess: { $0 == Self.macOS27WindowManagerProcessIdentifier }
        )
        #expect(windowNumber == 19)
    }

    @Test("WindowManager's window wins over one of the Dock's")
    func windowManagerWinsOverTheDock() {
        let dockWindow = Self.windowDescription(
            number: 5,
            ownerName: "程序坞",
            ownerProcessIdentifier: Self.macOS27DockProcessIdentifier,
            level: -2147483624,
            bounds: Self.macOS27DisplayBounds
        )
        let windowNumber = WallpaperSnapshot.wallpaperWindowNumber(
            in: [dockWindow] + Self.macOS27Windows,
            displayBounds: Self.macOS27DisplayBounds,
            desktopIconWindowLevel: Self.desktopIconWindowLevel,
            dockProcessIdentifier: Self.macOS27DockProcessIdentifier,
            isWindowManagerProcess: { $0 == Self.macOS27WindowManagerProcessIdentifier }
        )
        #expect(windowNumber == 19)
    }

    @Test("a display nobody draws a wallpaper on has none")
    func noWallpaperWindow() {
        let windowNumber = WallpaperSnapshot.wallpaperWindowNumber(
            in: Self.macOS26Windows,
            displayBounds: CGRect(x: 1491, y: 0, width: 1920, height: 1080),
            desktopIconWindowLevel: Self.desktopIconWindowLevel,
            dockProcessIdentifier: Self.macOS26DockProcessIdentifier,
            isWindowManagerProcess: { _ in false }
        )
        #expect(windowNumber == nil)
    }
}
