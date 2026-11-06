import CoreGraphics
import Darwin
import Foundation
import OSToolbox

/// A still image of the desktop picture, for the springboard's background.
///
/// macOS 15's Dock captured its own wallpaper window when Launchpad opened. On macOS 27 the wallpaper
/// windows belong to WindowManager — one named `Wallpaper` per Space, just below the desktop level — so
/// this captures the one on screen for the display, with the same SkyLight call and options 15 used
/// (`CGSHWCaptureWindowList(…, 0x11944)`). The Dock is entitled to capture windows; the payload inherits
/// that. Desktop icons and widgets are other windows and stay out of the picture, as in 15.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "WallpaperSnapshot")
enum WallpaperSnapshot {
    private typealias CaptureWindowListFunction = @convention(c) (UInt32, UnsafeMutablePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?

    /// The options the 15.5 Dock and the 27.2 WindowManager both pass.
    private static let captureOptions: UInt32 = 0x11944

    /// `RTLD_DEFAULT`, which Swift does not import because the C macro is a pointer cast.
    private static var defaultSymbolSearchHandle: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }

    static func captureWallpaperImage(onDisplay displayIdentifier: CGDirectDisplayID) -> CGImage? {
        guard var windowIdentifier = wallpaperWindowIdentifier(onDisplay: displayIdentifier) else {
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

    /// WindowManager's on-screen window that covers the display below the desktop icons.
    private static func wallpaperWindowIdentifier(onDisplay displayIdentifier: CGDirectDisplayID) -> CGWindowID? {
        guard let windowDescriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let displayBounds = CGDisplayBounds(displayIdentifier)
        let desktopIconWindowLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        for windowDescription in windowDescriptions {
            guard
                (windowDescription[kCGWindowOwnerName as String] as? String) == "WindowManager",
                let windowLevel = (windowDescription[kCGWindowLayer as String] as? NSNumber)?.intValue,
                windowLevel < desktopIconWindowLevel,
                let boundsDictionary = windowDescription[kCGWindowBounds as String] as? NSDictionary,
                let windowBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                windowBounds == displayBounds,
                let windowNumber = (windowDescription[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            return windowNumber
        }
        return nil
    }
}
