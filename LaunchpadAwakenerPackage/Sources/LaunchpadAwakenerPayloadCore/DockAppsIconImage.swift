import CoreGraphics
import Foundation
import OSToolbox
import LaunchpadAwakenerPrivateInterfaces
import LaunchpadAwakenerSpringboardCore

/// Renders the Launchpad icon the Dock's Apps tile is given, in the appearance the Dock is drawing in.
///
/// ## Why IconServices and not the icon file
///
/// A compiled `.icns` holds one appearance. macOS 26 and 27 give an application icon three — light, dark
/// and tinted — and keep them as layered `iconstack` resources inside the app's asset catalog, which only
/// IconServices renders. Handing the Dock a picture decoded from an `.icns` therefore leaves the Apps tile
/// in the light appearance while every other tile around it turns dark, which is worse than not changing
/// the tile at all.
///
/// So the icon comes from the same place the Dock's own tiles come from: `ISIcon` over a bundle, with a
/// descriptor copied from the Dock's own (``DockEnvironment/iconAppearance``). That descriptor carries the
/// appearance, the clear and tinted variants, and the tint colour the user chose, so the substitute
/// follows all of them without this code knowing what any of them mean. It is also how the replica draws
/// every icon inside Launchpad (``SpringboardIconProvider``).
///
/// ## Why it never renders on the Dock's thread
///
/// The Dock asks for a tile's image while it is drawing, and IconServices blocks while it renders. So the
/// hook only ever reads the cache; a miss leaves the Dock's own icon in place for that pass and starts a
/// render in the background, after which the tile is asked to draw again and the second pass hits.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockAppsIconImage")
enum DockAppsIconImage {
    /// Everything that changes what the rendering looks like.
    ///
    /// The appearance fields rather than the descriptor itself: the Dock replaces its descriptor whenever
    /// the appearance changes, so the object's identity says nothing, while these fields are exactly what
    /// `ISImageDescriptor` renders from.
    struct CacheKey: Hashable, Sendable {
        let bundlePath: String
        let pixelWidth: Int
        let scale: Double
        let appearance: Int
        let appearanceVariant: Int
        let background: UInt
        /// The tint colour as it describes itself; nil when the appearance is not a tinted one.
        let tintColorDescription: String?
    }

    /// Rendered icons, by what they were rendered for. Small: one entry per appearance per tile size.
    private static let imagesByCacheKey = OSAllocatedUnfairLock<[CacheKey: CGImage]>(initialState: [:])

    /// Keys a background render is already running for, so a tile drawn repeatedly starts one render.
    private static let keysBeingRendered = OSAllocatedUnfairLock<Set<CacheKey>>(initialState: [])

    /// The pixel width to render at when the Dock hands over no image to measure: 128 points at 2×, the
    /// usual tile size on a Retina display.
    private static let fallbackPixelWidth = 256

    // MARK: - What the hook asks

    /// What to render for a tile whose own image is `originalImage`; nil when the Dock's appearance is out
    /// of reach, in which case the tile is left alone.
    ///
    /// - Parameter originalImage: What the Dock was about to draw, consulted only for its pixel width, so
    ///   the substitute is neither blurry nor needlessly large. The Dock's own scale-factor handling
    ///   produced that width, which makes matching it more reliable than deciding on a size here.
    static func cacheKey(bundlePath: String, matchingWidthOf originalImage: CGImage?) -> CacheKey? {
        guard let descriptor = currentDockDescriptor() as? ISImageDescriptor else { return nil }
        let scale = descriptor.scale > 0 ? descriptor.scale : 2
        return CacheKey(
            bundlePath: bundlePath,
            pixelWidth: originalImage?.width ?? fallbackPixelWidth,
            scale: scale,
            appearance: descriptor.appearance,
            appearanceVariant: descriptor.appearanceVariant,
            background: descriptor.background,
            tintColorDescription: descriptor.tintColor?.description
        )
    }

    /// The rendering for `cacheKey`, or nil when it has not been rendered yet. Never blocks.
    static func cachedImage(for cacheKey: CacheKey) -> CGImage? {
        imagesByCacheKey.withLock { cache in cache[cacheKey] }
    }

    /// Renders for `cacheKey` off the Dock's thread, unless a render for it is already running.
    ///
    /// `whenRendered` runs only when this call is what produced the image, so the caller can ask the Dock
    /// to draw the tile again exactly once.
    static func renderInBackground(for cacheKey: CacheKey, whenRendered: @escaping @Sendable () -> Void) {
        let shouldStart = keysBeingRendered.withLock { keys -> Bool in
            guard !keys.contains(cacheKey) else { return false }
            keys.insert(cacheKey)
            return true
        }
        guard shouldStart else { return }

        // The descriptor is built here, on the Dock's thread, because it copies the Dock's own; the copy
        // is then this task's alone.
        let descriptorBox = UncheckedSendableBox(value: makeDescriptor(for: cacheKey))
        Task.detached(priority: .userInitiated) {
            defer { keysBeingRendered.withLock { keys in keys.remove(cacheKey) } }
            guard let descriptor = descriptorBox.value else {
                #log(.error, "No icon descriptor for the Apps tile; it keeps the Dock's own icon")
                return
            }
            guard let image = IconServicesBridge.makeIconImage(
                forFileAt: URL(fileURLWithPath: cacheKey.bundlePath),
                descriptor: descriptor
            ) else {
                #log(.error, "IconServices has no icon for \(cacheKey.bundlePath, privacy: .public); the Apps tile keeps the Dock's own icon")
                return
            }
            imagesByCacheKey.withLock { cache in cache[cacheKey] = image }
            // One line per appearance and tile size, so a handful per login session. It is what says which
            // appearance the Dock was in when it asked, which is the thing to look at when the tile is the
            // wrong colour — and the thing an `.icns` could never have followed.
            #log(
                .default,
                "Rendered the Apps tile's icon: appearance \(cacheKey.appearance, privacy: .public) variant \(cacheKey.appearanceVariant, privacy: .public)\(cacheKey.tintColorDescription == nil ? "" : ", tinted", privacy: .public) at \(cacheKey.pixelWidth, privacy: .public)px"
            )
            whenRendered()
        }
    }

    /// A descriptor for `cacheKey`: the Dock's own, copied, with the size this tile needs.
    private static func makeDescriptor(for cacheKey: CacheKey) -> NSObject? {
        IconServicesBridge.makeDescriptor(
            copying: currentDockDescriptor(),
            pointSize: CGFloat(cacheKey.pixelWidth) / cacheKey.scale,
            scale: cacheKey.scale
        )
    }

    /// The Dock's own icon descriptor, read where the Dock itself is.
    ///
    /// Both callers run from the Dock's icon setter, which the Dock calls while it draws — on its main
    /// thread. The check is what makes that an assertion rather than an assumption: being wrong about it
    /// would trap inside somebody else's process, and the icon is not worth that. Being on another thread
    /// costs the substitution for that pass, and the next pass on the main thread puts it right.
    private static func currentDockDescriptor() -> NSObject? {
        guard Thread.isMainThread else { return nil }
        // Boxed only to cross the isolation boundary: the descriptor is the Dock's, and the one thing
        // done with it — copying it — happens right here, on the same thread.
        return MainActor.assumeIsolated {
            UncheckedSendableBox(value: DockEnvironment.iconAppearance?.iconDescriptor)
        }.value
    }

    /// Drops everything rendered so far. For the moments the icon's source changes under the payload.
    static func forgetRenderings() {
        imagesByCacheKey.withLock { cache in cache.removeAll() }
    }

    // MARK: - The Dock's image argument

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
