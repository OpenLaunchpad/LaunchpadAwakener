import CoreGraphics
import Foundation
import QuartzCore

/// What lies behind the pages.
///
/// By default macOS 15's: the wallpaper as captured on opening, blurred, saturated and darkened by
/// 15's three filters in a rasterized container (`-[Springboard init]`, 15.5 `0x100007C48`;
/// `_applyDesktopFilters` `0x10002E120`), or 15's own radial gradient when there is no picture
/// (`-[Springboard _newDesktopLayer]`, `0x100090670`). App windows stay hidden behind it, as in 15.
///
/// `springboard-background` set to `glass` puts the Dock's own Liquid Glass there instead
/// (``DockGlassMaterial``), over whatever is behind the window: always in its dark appearance, so 15's
/// white titles stay legible, and reaching past every edge so that its rim stays off screen. Without
/// the Dock's glass, a window-server backdrop with 15's filters stands in.
@MainActor
final class SpringboardBackground {
    enum Style: String {
        case wallpaper
        case glass
    }

    /// How far the glass reaches past each edge of the screen, enough to keep its rim out of sight.
    static let glassOutset: CGFloat = 64
    /// Backdrops in one group share a capture and cannot see each other; the Dock's own groups are
    /// `dock-bar` and `bezelList`.
    static let backdropGroupName = "launchpad-background"

    let style: Style
    /// Fills the screen; the glass's own layers reach past it.
    let layer = CALayer()
    private var glass: DockGlassMaterial?

    /// - Parameter wallpaperImage: The wallpaper as captured on opening, for the wallpaper style; nil
    ///   leaves 15's gradient.
    init(style: Style, frame: CGRect, scale: CGFloat, wallpaperImage: CGImage?) {
        self.style = style
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        switch style {
        case .wallpaper:
            // 15's `_desktopContainerLayer`: the filters are worked out once, when it is rasterized.
            layer.shouldRasterize = true
            layer.rasterizationScale = scale
            layer.filters = QuartzCorePrivate.desktopBackgroundFilters()
            layer.addSublayer(Self.makeDesktopLayer(image: wallpaperImage, frame: layer.bounds))
        case .glass:
            // A group would be drawn off screen, where a window-server backdrop has nothing behind it.
            layer.allowsGroupOpacity = false
            addGlass(scale: scale)
        }
        CATransaction.commit()
    }

    /// Whether the Dock's glass is shown.
    var isGlass: Bool {
        glass != nil
    }

    private func addGlass(scale: CGFloat) {
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
            return
        }
        let backdropLayer = QuartzCorePrivate.makeBackdropLayer(isWindowServerAware: true)
        backdropLayer.frame = layer.bounds
        backdropLayer.filters = QuartzCorePrivate.desktopBackgroundFilters()
        layer.addSublayer(backdropLayer)
    }

    /// The wallpaper, stretched over the screen; 15's radial gradient when there is no picture.
    private static func makeDesktopLayer(image: CGImage?, frame: CGRect) -> CALayer {
        guard let image else {
            let gradientLayer = CAGradientLayer()
            gradientLayer.type = .radial
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.6)
            gradientLayer.endPoint = CGPoint(x: 1.2, y: 1.5)
            gradientLayer.colors = [
                CGColor(red: 0.251, green: 0.254, blue: 0.284, alpha: 1),
                CGColor(red: 0.132, green: 0.132, blue: 0.147, alpha: 1),
            ]
            gradientLayer.frame = frame
            return gradientLayer
        }
        let desktopLayer = CALayer()
        desktopLayer.frame = frame
        desktopLayer.contents = image
        return desktopLayer
    }
}
