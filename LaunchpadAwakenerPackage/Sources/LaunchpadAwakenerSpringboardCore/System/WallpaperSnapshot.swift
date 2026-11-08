import CoreGraphics
import Darwin
import Foundation
import OSToolbox

/// A still image of the desktop picture, for the springboard's background.
///
/// macOS 15's Dock captured its own wallpaper window when Launchpad opened, and macOS 26's Dock still
/// draws the wallpaper itself (a window named `Wallpaper-`). On macOS 27 the wallpaper windows belong to
/// WindowManager — one named `Wallpaper` per Space, at the same level just below the desktop icons. This
/// captures the one on screen for the display, with the same SkyLight call and options 15 used
/// (`CGSHWCaptureWindowList(…, 0x11944)`). The Dock is entitled to capture windows; the payload inherits
/// that. Desktop icons and widgets are other windows and stay out of the picture, as in 15.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "WallpaperSnapshot")
package enum WallpaperSnapshot {
    private typealias CaptureWindowListFunction = @convention(c) (UInt32, UnsafeMutablePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?

    /// The options the 15.5 Dock and the 27.2 WindowManager both pass.
    private static let captureOptions: UInt32 = 0x11944

    /// `RTLD_DEFAULT`, which Swift does not import because the C macro is a pointer cast.
    private static var defaultSymbolSearchHandle: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }

    /// `dockProcessIdentifier` tells the Dock's own wallpaper window (macOS 26) from other windows; inside
    /// the Dock it is this process.
    package static func captureWallpaperImage(onDisplay displayIdentifier: CGDirectDisplayID, dockProcessIdentifier: pid_t = getpid()) -> CGImage? {
        guard var windowIdentifier = wallpaperWindowIdentifier(onDisplay: displayIdentifier, dockProcessIdentifier: dockProcessIdentifier) else {
            #log(.error, "No wallpaper window on display \(displayIdentifier, privacy: .public)")
            return nil
        }
        guard
            let connectionIdentifier = SkyLightBridge.mainConnectionIdentifier,
            let captureSymbol = dlsym(defaultSymbolSearchHandle, "SLSHWCaptureWindowList")
        else { return nil }
        let captureWindowList = unsafeBitCast(captureSymbol, to: CaptureWindowListFunction.self)
        guard
            let capturedImages = captureWindowList(connectionIdentifier, &windowIdentifier, 1, captureOptions)?.takeRetainedValue() as NSArray?,
            let firstCapturedObject = capturedImages.firstObject,
            CFGetTypeID(firstCapturedObject as CFTypeRef) == CGImage.typeID
        else {
            #log(.error, "Capturing wallpaper window \(windowIdentifier, privacy: .public) returned no image")
            return nil
        }
        return (firstCapturedObject as! CGImage)
    }

    /// The on-screen window that covers the display below the desktop icons.
    private static func wallpaperWindowIdentifier(onDisplay displayIdentifier: CGDirectDisplayID, dockProcessIdentifier: pid_t) -> CGWindowID? {
        guard let windowDescriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return wallpaperWindowNumber(
            in: windowDescriptions,
            displayBounds: CGDisplayBounds(displayIdentifier),
            desktopIconWindowLevel: Int(CGWindowLevelForKey(.desktopIconWindow)),
            dockProcessIdentifier: dockProcessIdentifier,
            isWindowManagerProcess: isWindowManagerProcess(_:)
        )
    }

    /// Picks the wallpaper window out of a window list as `CGWindowListCopyWindowInfo` returns it: a window
    /// covering the whole display below the desktop icons, drawn by WindowManager (macOS 27) or by the Dock
    /// itself (macOS 26). WindowManager's wins when both are there.
    ///
    /// Owners are told apart by process, not by `kCGWindowOwnerName`, which is the localized name — 26's
    /// Dock is 「程序坞」 on a Simplified Chinese system. Other windows of the same size and level, such as
    /// the window server's backstop and the wallpaper agent's offscreen copy, are nobody's wallpaper.
    static func wallpaperWindowNumber(
        in windowDescriptions: [[String: Any]],
        displayBounds: CGRect,
        desktopIconWindowLevel: Int,
        dockProcessIdentifier: pid_t,
        isWindowManagerProcess: (pid_t) -> Bool
    ) -> CGWindowID? {
        var dockWindowNumber: CGWindowID?
        for windowDescription in windowDescriptions {
            guard
                let ownerProcessIdentifier = (windowDescription[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let windowLevel = (windowDescription[kCGWindowLayer as String] as? NSNumber)?.intValue,
                windowLevel < desktopIconWindowLevel,
                let boundsDictionary = windowDescription[kCGWindowBounds as String] as? NSDictionary,
                let windowBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                windowBounds == displayBounds,
                let windowNumber = (windowDescription[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            if isWindowManagerProcess(ownerProcessIdentifier) {
                return windowNumber
            }
            if ownerProcessIdentifier == dockProcessIdentifier, dockWindowNumber == nil {
                dockWindowNumber = windowNumber
            }
        }
        return dockWindowNumber
    }

    /// Whether the process runs `/System/Library/CoreServices/WindowManager.app`.
    private static func isWindowManagerProcess(_ processIdentifier: pid_t) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return false }
        let executablePath = String(decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return executablePath.hasSuffix("/WindowManager.app/Contents/MacOS/WindowManager")
    }
}
