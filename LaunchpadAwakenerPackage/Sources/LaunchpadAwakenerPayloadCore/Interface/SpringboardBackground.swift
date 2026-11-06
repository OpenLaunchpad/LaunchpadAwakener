import CoreGraphics
import Foundation
import QuartzCore

/// What lies behind the pages: glass over whatever is behind the window.
///
/// macOS 15 showed a blurred, darkened snapshot of the wallpaper here. On macOS 27 this is the Dock's
/// own Liquid Glass (``DockGlassMaterial``) instead, always in its dark appearance and not adapting to
/// what is behind it: the titles keep 15's white text and shadow, which a light glass would wash out.
/// The glass reaches past every edge of the screen so that its rim stays off screen. Without the Dock's
/// glass, a backdrop with 15's blur, saturation and darkening stands in.
@MainActor
final class SpringboardBackground {
    /// How far the glass reaches past each edge of the screen, enough to keep its rim out of sight.
    static let glassOutset: CGFloat = 64
    /// Backdrops in one group share a capture and cannot see each other; the Dock's own groups are
    /// `dock-bar` and `bezelList`.
    static let backdropGroupName = "launchpad-background"

    /// Fills the screen; the glass's own layers reach past it.
    let layer = CALayer()
    private let glass: DockGlassMaterial?

    init(frame: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        // A group would be drawn off screen, where a window-server backdrop has nothing behind it.
        layer.allowsGroupOpacity = false
        let glass = DockGlassMaterial(variant: SpringboardPreferences.glassVariant, isAdaptive: false)
        let isGlassShown = glass?.update(
            frame: layer.bounds.insetBy(dx: -Self.glassOutset, dy: -Self.glassOutset),
            cornerRadius: 0,
            isDark: true,
            displayScale: scale,
            backdropGroupName: Self.backdropGroupName
        ) ?? false
        if let glass, isGlassShown {
            layer.addSublayer(glass.rootLayer)
            self.glass = glass
        } else {
            let backdropLayer = QuartzCorePrivate.makeBackdropLayer(isWindowServerAware: true)
            backdropLayer.frame = layer.bounds
            backdropLayer.backgroundFilters = QuartzCorePrivate.desktopBackgroundFilters()
            layer.addSublayer(backdropLayer)
            self.glass = nil
        }
        CATransaction.commit()
    }

    /// Whether the Dock's glass is shown, rather than the stand-in blur.
    var isGlass: Bool {
        glass != nil
    }
}
