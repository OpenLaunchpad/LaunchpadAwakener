import Foundation
import ObjCRuntimeToolbox
import ObjectiveC
import OSToolbox

/// The two calls that identify a Dock tile and make the Dock draw it again.
///
/// `fileURL` is declared on `Tile` itself, which is what makes it the right question to ask: the Dock
/// uses two different classes for an application that is running and one that is not (`DOCKProcessTile`
/// and `DOCKFileTile`), and only the former answers `bundleIdentifier` — the base class returns nothing.
///
/// `render` is the Dock's own way of redrawing a tile, and it is where the Dock calls its icon setter.
/// So asking a tile to render is how an override is both applied and undone: with the hook installed and
/// the override on, the Dock's image is substituted on the way through; with it off, the Dock's own icon
/// goes back up. Nothing here has to keep a copy of the image it displaced.
@RuntimeClassProxy("Tile")
protocol DockTileIconAccess {
    /// The bundle this tile stands for; nil for tiles that are not files, such as the Trash or a stack.
    var fileURL: NSURL? { get }
    /// Redraws the tile, which goes through the Dock's own icon setter.
    func render()
}

/// `-[DockBar tiles]`, every tile the Dock has. One tile is enough to reach the rest, but the payload
/// already finds the `DockBar` itself (``DockBarReference``), so the list is asked for directly.
@RuntimeClassProxy("DockBar")
protocol DockBarTileList {
    var tiles: NSArray? { get }
}

/// Finds the Dock's Apps tile, and asks the Dock to draw it again.
///
/// Identity is resolved from the tile's own bundle rather than from a Dock-internal notion of "the Apps
/// tile", because the Dock has none: Apps is an ordinary application tile. Both macOS 26.6.2 and 27.2
/// name it `com.apple.apps.launcher`, the identifier their Dock binaries carry.
///
/// Everything here is optional to the replica: when the Dock no longer matches, ``isCompatible`` is false,
/// the icon override is off, and Launchpad is unaffected. So these signatures are deliberately *not* in
/// ``DockHostInterface/requiredMethods``, which would switch the whole payload off instead.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockAppsTile")
enum DockAppsTile {
    // MARK: - Identity

    /// Bundle identifier of the system's Apps, the same on macOS 26.6.2 and 27.2.
    static let appsBundleIdentifier = "com.apple.apps.launcher"

    /// Where that bundle lives, checked before the identifier so that the common tile — which is not Apps
    /// — costs a string comparison rather than a read of its `Info.plist`.
    static let appsBundlePath = "/System/Applications/Apps.app"

    /// Bundle path to "is this Apps", including the negative answers.
    ///
    /// Caching the misses matters more than caching the hits. The hook that uses this sits on the Dock's
    /// rendering path — every icon-size change, appearance change and application launch sets tile images
    /// — and all but one tile is a miss, so misses are what gets asked about.
    private static let isAppsByBundlePath = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    /// Whether `tile` stands for the system's Apps.
    ///
    /// Safe to call from the Dock's rendering path on any thread: the lock is held across a dictionary
    /// access only, never across a call into the Dock.
    static func isAppsTile(_ tile: AnyObject) -> Bool {
        guard let fileURL = DockTileIconAccessImplementation(tile)?.fileURL as URL? else { return false }
        return isAppsBundle(at: fileURL)
    }

    /// Whether the bundle at `fileURL` is the system's Apps.
    ///
    /// Apart from ``isAppsTile(_:)`` so that the rule — and its cache — can be exercised without a Dock
    /// to get a tile from.
    ///
    /// The path is compared before the identifier is read, because reading one means opening the bundle's
    /// `Info.plist`, and the answer for all but one tile is already settled by the path.
    static func isAppsBundle(at fileURL: URL) -> Bool {
        // `standardizedFileURL` so that one bundle reached by a path with a trailing slash or a `..` does
        // not get a cache entry of its own.
        let bundlePath = fileURL.standardizedFileURL.path
        if let cachedAnswer = isAppsByBundlePath.withLock({ cache in cache[bundlePath] }) {
            return cachedAnswer
        }

        let isApps = bundlePath == appsBundlePath
            || Bundle(url: fileURL)?.bundleIdentifier == appsBundleIdentifier
        isAppsByBundlePath.withLock { cache in cache[bundlePath] = isApps }
        return isApps
    }

    // MARK: - Signatures

    static let requiredMethods: [DockMethodSignature] =
        DockMethodSignature.signatures(
            ofClassNamed: DockTileIconAccessImplementation.runtimeClassName,
            requirements: DockTileIconAccessImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockBarTileListImplementation.runtimeClassName,
            requirements: DockBarTileListImplementation.methodRequirements
        )

    /// What the running Dock lacks of the methods used here; empty when everything matches.
    static let missingMethodNames: [String] = requiredMethods.compactMap { signature in
        signature.isPresent ? nil : signature.methodName
    }

    static var isCompatible: Bool {
        missingMethodNames.isEmpty
    }

    // MARK: - Reaching the tiles

    /// Every Apps tile the Dock has right now.
    ///
    /// A list rather than one tile because a bundle may sit in the Dock more than once. Empty when the
    /// `DockBar` cannot be reached, which is the normal answer in the first moments after the Dock starts
    /// — the payload can arrive before the Dock has built its singletons. Nothing is cached: the Dock
    /// creates and destroys tiles as it is rearranged.
    @MainActor
    static func appsTiles() -> [AnyObject] {
        guard isCompatible else { return [] }
        guard let dockBar = DockBarReference.dockBar else {
            #log(.error, "The Dock's tile container is out of reach; the Apps tile keeps its own icon for now")
            return []
        }
        guard let tiles = DockBarTileListImplementation(dockBar)?.tiles as? [AnyObject] else {
            #log(.error, "The Dock would not give its tile list; the Apps tile keeps its own icon")
            return []
        }
        return tiles.filter(isAppsTile)
    }

    /// Asks the Dock to draw `tile` again, which goes through its own icon setter.
    @MainActor
    static func render(_ tile: AnyObject) {
        DockTileIconAccessImplementation(tile)?.render()
    }
}
