import CoreGraphics
import Foundation
import OSToolbox
import LaunchpadAwakenerPayloadInterface
import LaunchpadAwakenerSpringboardCore

/// Puts the Launchpad icon on the Dock's Apps tile, and takes it off again.
///
/// ## Why the tile is worth changing
///
/// Once the payload is in, every way of opening Apps opens this replica of Launchpad instead. The tile
/// in the Dock still shows the system's Apps icon, which is then a picture of something the click no
/// longer does.
///
/// ## How it is applied
///
/// Through the one hook on the Dock's own icon path (``DockTileIconHooksWithCompositingFilter`` and
/// ``DockTileIconHooksWithoutCompositingFilter``), which substitutes the image on its way to the Apps
/// tile and forwards every other tile untouched. Changing the switch asks the Dock to render the tile
/// again, which is how a tile the Dock drew before the payload arrived comes into line, and how the
/// Dock's own icon comes back when the switch goes off — the Dock redraws from its own sources, so
/// nothing here has to keep a copy of the image it displaced.
///
/// ## Why it starts off
///
/// The app owns this preference and sends it over the channel, path included, so a payload that has not
/// been told anything leaves the Dock alone. That is also the state for the moments between a Dock
/// restart and the app re-injecting and reconnecting.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockAppsIconOverride")
enum DockAppsIconOverride {
    private struct Settings: Equatable, Sendable {
        var isEnabled = false
        /// Absolute path of the image to use; nil until the app has sent one.
        var iconPath: String?
    }

    private static let settings = OSAllocatedUnfairLock(initialState: Settings())

    /// Whether the hook that does the substituting is in place. Set once, by ``PayloadEntry``.
    private static let isHookInstalled = OSAllocatedUnfairLock(initialState: false)

    static func noteHookInstalled() {
        isHookInstalled.withLock { isInstalled in isInstalled = true }
    }

    /// Why this payload cannot change the tile, or nil when it can.
    ///
    /// Two separate reasons, because either can hold on its own: the hook is what substitutes the image,
    /// and the calls in ``DockAppsTile`` are what reach a tile that is already on screen.
    static var unsupportedReason: String? {
        if !isHookInstalled.withLock({ isInstalled in isInstalled }) {
            return "This Dock's icon setter does not match what the payload recorded for it"
        }
        if !DockAppsTile.isCompatible {
            return "This Dock lacks \(DockAppsTile.missingMethodNames.joined(separator: ", "))"
        }
        return nil
    }

    // MARK: - The hook's question

    /// The image to draw instead of `originalImage`, or nil to leave the Dock's own image alone.
    ///
    /// Called from the Dock's rendering path for every tile it draws, so the checks are ordered by what
    /// they cost: the switch first, which skips resolving a bundle identifier entirely while the override
    /// is off; then the tile's identity, which is cached; then the image, which is cached too.
    static func substituteImage(for tile: AnyObject, replacing originalImage: AnyObject?) -> AnyObject? {
        let currentSettings = settings.withLock { settings in settings }
        guard currentSettings.isEnabled, let iconPath = currentSettings.iconPath else { return nil }
        guard DockAppsTile.isAppsTile(tile) else { return nil }

        // While the kill switch is on, clicking Apps opens the system's Apps, so the system's icon is the
        // honest picture of what the tile does. This is the one file-system look here, and only the Apps
        // tile ever reaches it. It corrects itself the moment it matters: opening the system's Apps makes
        // the Dock set that tile's icon, which comes straight back through here.
        guard !SpringboardController.isDisabledByKillSwitch else { return nil }

        // Nil here is a failure that was already logged — a missing or unreadable icon file. Forwarding
        // the Dock's own image costs the user their icon, not their Dock.
        guard let substituteImage = DockAppsIconImage.image(
            atPath: iconPath,
            matchingWidthOf: DockAppsIconImage.asCoreGraphicsImage(originalImage)
        ) else { return nil }

        noteFirstSubstitution()
        return substituteImage
    }

    /// Whether the log already carries the line below.
    private static let hasLoggedFirstSubstitution = OSAllocatedUnfairLock(initialState: false)

    /// Says once that the Dock actually came through here with the Apps tile.
    ///
    /// An installed hook and a hook the Dock calls are two different things, and the gap between them has
    /// no symptom: DockIconOverride spent macOS 27 hooking a spelling that installed cleanly, reported
    /// success, and was never called for an application icon. This line is what tells them apart from the
    /// log alone. `default` rather than `info`, which does not survive in the log store long enough to be
    /// read after a system upgrade.
    private static func noteFirstSubstitution() {
        let isFirst = hasLoggedFirstSubstitution.withLock { hasLogged -> Bool in
            guard !hasLogged else { return false }
            hasLogged = true
            return true
        }
        guard isFirst else { return }
        #log(.default, "The Dock asked for the Apps tile's icon and was given Launchpad's")
    }

    // MARK: - What the app asks for

    /// Takes the app's switch and icon path, and brings the tiles already on screen into line.
    ///
    /// The Dock is asked to render only when something actually changed. The app sends this on every
    /// handshake, including the ones where it is only reconnecting to a payload that is already showing
    /// the right icon, and redrawing a tile for nothing is work on the Dock's main thread.
    static func apply(_ request: DockAppsIconRequest) async -> DockAppsIconReply {
        if let unsupportedReason {
            #log(.error, "Not changing the Apps tile: \(unsupportedReason, privacy: .public)")
            return .unsupported(reason: unsupportedReason)
        }

        let newSettings = Settings(isEnabled: request.isEnabled, iconPath: request.iconPath)
        let hasChanged = settings.withLock { settings -> Bool in
            guard settings != newSettings else { return false }
            settings = newSettings
            return true
        }

        let appsTileCount = await MainActor.run {
            let appsTiles = DockAppsTile.appsTiles()
            guard hasChanged else { return appsTiles.count }
            for tile in appsTiles {
                DockAppsTile.render(tile)
            }
            return appsTiles.count
        }

        if hasChanged {
            #log(
                .default,
                // "was asked to", not "now shows": the kill switch overrides this, and the tile may not be
                // on screen yet. What actually reached a tile is the line in ``noteFirstSubstitution()``.
                "The Apps tile was asked to show \(request.isEnabled ? "the Launchpad icon" : "the Dock's own icon", privacy: .public) (\(appsTileCount, privacy: .public) tile(s))"
            )
        }
        return .applied(appsTileCount: appsTileCount)
    }
}
