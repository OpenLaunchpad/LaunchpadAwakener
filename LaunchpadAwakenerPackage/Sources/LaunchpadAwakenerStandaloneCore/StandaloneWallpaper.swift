import AppKit
import ImageIO
import LaunchpadAwakenerSpringboardCore
import OSToolbox

/// The wallpaper behind the standalone springboard, without ever asking for a permission.
///
/// Capturing the wallpaper window — what the Dock does — needs screen recording, so it is done only when
/// the user has already allowed it; `CGPreflightScreenCaptureAccess()` asks nothing. Otherwise the picture
/// comes from the wallpaper's file, and of a dynamic wallpaper the image for the current appearance or
/// time of day. A wallpaper with no readable picture, such as a video one, leaves 15's gradient.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "StandaloneWallpaper")
@MainActor
enum StandaloneWallpaper {
    enum Source: String {
        case capturedWindow = "the captured wallpaper window"
        case wallpaperFile = "the wallpaper file"
    }

    static func image(onDisplay displayIdentifier: CGDirectDisplayID) -> (image: CGImage, source: Source)? {
        if CGPreflightScreenCaptureAccess(),
           let dockProcessIdentifier = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
           let capturedImage = WallpaperSnapshot.captureWallpaperImage(onDisplay: displayIdentifier, dockProcessIdentifier: dockProcessIdentifier) {
            return (capturedImage, .capturedWindow)
        }
        guard
            let screen = StandaloneEnvironment.screen(forDisplay: displayIdentifier),
            let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen)
        else {
            #log(.error, "No wallpaper file for display \(displayIdentifier, privacy: .public)")
            return nil
        }
        guard let image = image(fromFileAt: wallpaperURL, isDark: isDarkAppearance, now: Date()) else {
            #log(.error, "No picture in the wallpaper file \(wallpaperURL.path, privacy: .public)")
            return nil
        }
        return (image, .wallpaperFile)
    }

    /// The picture in an image file; of a dynamic wallpaper, the one it shows now.
    nonisolated static func image(fromFileAt fileURL: URL, isDark: Bool, now: Date, calendar: Calendar = .current) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil), CGImageSourceGetCount(imageSource) > 0 else { return nil }
        let imageCount = CGImageSourceGetCount(imageSource)
        let shownIndex = StandaloneDynamicWallpaper.shownImageIndex(in: imageSource, isDark: isDark, now: now, calendar: calendar)
        let index = shownIndex.flatMap { (0..<imageCount).contains($0) ? $0 : nil } ?? 0
        return CGImageSourceCreateImageAtIndex(imageSource, index, nil)
    }

    private static var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// Which image of a dynamic desktop picture shows now. macOS keeps the schedule in the HEIC's XMP, under
/// `apple_desktop:` — a base64 property list: `apr` picks by appearance (`l` light, `d` dark), `solar` has
/// the same pair under `ap`, and `h24` lists times of day (`ti`: `t` a fraction of the day, `i` the image).
enum StandaloneDynamicWallpaper {
    static func shownImageIndex(in imageSource: CGImageSource, isDark: Bool, now: Date, calendar: Calendar) -> Int? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil) else { return nil }
        if let appearanceSchedule = propertyList(named: "apr", in: metadata) as? [String: Any] {
            return imageIndex(forAppearanceSchedule: appearanceSchedule, isDark: isDark)
        }
        if let solarSchedule = propertyList(named: "solar", in: metadata) as? [String: Any],
           let appearanceSchedule = solarSchedule["ap"] as? [String: Any] {
            return imageIndex(forAppearanceSchedule: appearanceSchedule, isDark: isDark)
        }
        if let timeSchedule = propertyList(named: "h24", in: metadata) as? [String: Any],
           let timeEntries = timeSchedule["ti"] as? [[String: Any]] {
            return imageIndex(forTimeEntries: timeEntries, dayFraction: dayFraction(of: now, calendar: calendar))
        }
        return nil
    }

    /// `l` in the light appearance, `d` in the dark one.
    static func imageIndex(forAppearanceSchedule appearanceSchedule: [String: Any], isDark: Bool) -> Int? {
        (appearanceSchedule[isDark ? "d" : "l"] as? NSNumber)?.intValue
    }

    /// The last entry at or before `dayFraction`; before the first one of the day, the last of the day
    /// before.
    static func imageIndex(forTimeEntries timeEntries: [[String: Any]], dayFraction: Double) -> Int? {
        let entries = timeEntries.compactMap { entry -> (time: Double, index: Int)? in
            guard let time = (entry["t"] as? NSNumber)?.doubleValue, let index = (entry["i"] as? NSNumber)?.intValue else { return nil }
            return (time, index)
        }.sorted { $0.time < $1.time }
        return (entries.last { $0.time <= dayFraction } ?? entries.last)?.index
    }

    static func dayFraction(of date: Date, calendar: Calendar) -> Double {
        let startOfDay = calendar.startOfDay(for: date)
        return date.timeIntervalSince(startOfDay) / (24 * 60 * 60)
    }

    private static func propertyList(named name: String, in metadata: CGImageMetadata) -> Any? {
        guard
            let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "apple_desktop:\(name)" as CFString),
            let encodedValue = CGImageMetadataTagCopyValue(tag) as? String,
            let data = Data(base64Encoded: encodedValue)
        else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}
