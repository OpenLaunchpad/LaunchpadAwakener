import CoreGraphics
import Foundation
import ImageIO
import OSToolbox

/// Decodes the image the Dock's Apps tile is given, from a file on disk.
///
/// Built on ImageIO and Core Graphics with no AppKit. This runs inside the Dock, which draws through
/// Core Animation and SkyLight; the image the Dock wants is a `CGImage` it hands to `CALayer.contents`,
/// so there is nothing for AppKit to do, and pulling it into a process that does not already use it is
/// a good way to cause trouble.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockAppsIconImage")
enum DockAppsIconImage {
    private struct CacheKey: Hashable {
        let path: String
        let modificationDate: Date?
        let pixelWidth: Int
    }

    /// Decoding on every call would put an image decode on the Dock's rendering path. The modification
    /// date is part of the key, so replacing the app — which replaces the icon file — takes effect
    /// without restarting the Dock.
    private static let imagesByCacheKey = OSAllocatedUnfairLock<[CacheKey: CGImage]>(initialState: [:])

    /// The pixel width to decode at when the Dock hands over no image to measure: 128 points at 2×, the
    /// usual tile size on a Retina display.
    private static let fallbackPixelWidth = 256

    /// The image at `path`, decoded for a tile whose own image is `originalImage`.
    ///
    /// - Parameter originalImage: What the Dock was about to draw, consulted only for its pixel width, so
    ///   the substitute is neither blurry nor needlessly large. The Dock's own scale-factor handling
    ///   produced that width, which makes matching it more reliable than deciding on a size here.
    static func image(atPath path: String, matchingWidthOf originalImage: CGImage?) -> CGImage? {
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        let targetPixelWidth = originalImage?.width ?? fallbackPixelWidth
        let cacheKey = CacheKey(path: path, modificationDate: modificationDate, pixelWidth: targetPixelWidth)

        if let cachedImage = imagesByCacheKey.withLock({ cache in cache[cacheKey] }) {
            return cachedImage
        }

        guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            #log(.error, "Cannot read the icon at \(path, privacy: .public); the Apps tile keeps the Dock's own icon")
            return nil
        }

        // An .icns holds many representations and index 0 is not necessarily the largest, so ImageIO is
        // asked for a thumbnail instead of an image: it picks the representation that best matches the
        // requested size and scales from there.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelWidth,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            #log(.error, "Cannot decode the icon at \(path, privacy: .public); the Apps tile keeps the Dock's own icon")
            return nil
        }

        imagesByCacheKey.withLock { cache in cache[cacheKey] = image }
        return image
    }

    /// Bridges the `id`-typed image argument of the Dock's icon setter to a `CGImage`.
    ///
    /// The Dock declares that parameter as an object, but what travels through it is a `CGImageRef` — it
    /// ends up as `CALayer.contents`. Checking the Core Foundation type before casting means a future
    /// change in what the Dock passes costs the size hint rather than crashing the Dock.
    static func asCoreGraphicsImage(_ object: AnyObject?) -> CGImage? {
        guard let object, CFGetTypeID(object) == CGImage.typeID else { return nil }
        return unsafeDowncast(object, to: CGImage.self)
    }
}
