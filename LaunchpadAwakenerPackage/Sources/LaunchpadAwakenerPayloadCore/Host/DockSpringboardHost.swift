import CoreGraphics
import Foundation
import QuartzCore
import LaunchpadAwakenerSpringboardCore

/// The springboard's host inside the Dock: the Dock's own window, layer classes, glass and uninstaller,
/// the text input helper for the fields and the deletion confirmation, and the Dock's preferences domain.
///
/// Holds no state of its own; everything is read from the Dock as it is asked for.
final class DockSpringboardHost: SpringboardHost {
    nonisolated init() {}

    nonisolated var layerFactory: any SpringboardLayerFactory {
        DockSpringboardLayerFactory()
    }

    /// Inside the Dock, the standard defaults are the `com.apple.dock` domain.
    nonisolated var preferences: UserDefaults {
        .standard
    }

    nonisolated var libraryConfiguration: LaunchpadLibrary.Configuration {
        .standard(itemsPerPage: SpringboardPreferences.itemsPerPage)
    }

    /// Inside the Dock, its main bundle.
    nonisolated var resourceBundle: Bundle? {
        Bundle.main
    }

    var dockGeometry: SpringboardDockGeometry {
        SpringboardDockGeometry(
            orientation: DockEnvironment.dockOrientation,
            thickness: DockEnvironment.dockThickness,
            notchHeight: DockEnvironment.notchHeight
        )
    }

    var iconStyle: SpringboardIconStyle? {
        DockEnvironment.iconAppearance.map { SpringboardIconStyle(iconDescriptor: $0.iconDescriptor, style: $0.style) }
    }

    var applicationUninstaller: (any SpringboardApplicationUninstaller)? {
        DockApplicationUninstaller.isAvailable ? DockSpringboardUninstaller.shared : nil
    }

    func makeWindow(onDisplay displayIdentifier: CGDirectDisplayID) -> (any SpringboardWindow)? {
        DockSpringboardWindow(displayIdentifier: displayIdentifier)
    }

    func wallpaperImage(onDisplay displayIdentifier: CGDirectDisplayID) -> CGImage? {
        WallpaperSnapshot.captureWallpaperImage(onDisplay: displayIdentifier)
    }

    /// The Dock's own glass, or the stand-in blur where the Dock's glass controller does not match.
    var offersGlassBackground: Bool {
        true
    }

    func makeGlassBackground(frame: CGRect, scale: CGFloat, backdropGroupName: String) -> (any SpringboardGlassBackground)? {
        guard let glass = DockGlassMaterial(variant: SpringboardPreferences.glassVariant, isAdaptive: false) else { return nil }
        let isGlassShown = glass.update(frame: frame, cornerRadius: 0, isDark: true, displayScale: scale, backdropGroupName: backdropGroupName)
        return isGlassShown ? glass : nil
    }

    func makeHostedTextField(configuration: SpringboardHostedTextFieldConfiguration) -> (any SpringboardHostedTextField)? {
        SpringboardRemoteTextField(configuration: configuration)
    }

    func makeHostedDeletionConfirmation(configuration: SpringboardHostedDeletionConfirmationConfiguration) -> (any SpringboardHostedDeletionConfirmation)? {
        SpringboardRemoteDeletionConfirmation(configuration: configuration)
    }

    /// The Dock is not an application input methods serve; the text input helper stands in.
    var inputMethod: (any SpringboardInputMethod)? {
        nil
    }

    func isOnDock(_ globalPoint: CGPoint) -> Bool {
        DockBarReference.currentBarRect?.contains(globalPoint) ?? false
    }

    func setDockVisibility(_ visibility: SpringboardDockVisibility) {
        DockBarVisibility.shared.apply(visibility)
    }
}

/// The Dock's own `EC*` layer classes, through ``DockLayerFactory``.
struct DockSpringboardLayerFactory: SpringboardLayerFactory {
    func makePageGridLayer(source: SpringboardGridSource, rowCount: Int, columnCount: Int, scaleFactor: Float) -> CALayer? {
        DockLayerFactory.makeGridLayer(source: source, rowCount: rowCount, columnCount: columnCount, scaleFactor: scaleFactor)
    }

    func layoutPageGridLayer(_ gridLayer: CALayer) {
        DockLayerFactory.layoutGridLayer(gridLayer)
    }

    func makeThumbnailGridLayer(source: SpringboardThumbnailSource, rowCount: Int, columnCount: Int, spacing: UInt, scaleFactor: Float) -> CALayer? {
        DockLayerFactory.makeImageGridLayer(source: source, rowCount: rowCount, columnCount: columnCount, spacing: spacing, scaleFactor: scaleFactor)
    }

    func layoutThumbnailGridLayer(_ gridLayer: CALayer) {
        DockLayerFactory.layoutImageGridLayer(gridLayer)
    }

    func invalidateThumbnailGridLayer(_ gridLayer: CALayer, source: SpringboardThumbnailSource) {
        DockLayerFactory.invalidateImageGridLayer(gridLayer, source: source)
    }

    func scrollThumbnailGridLayer(_ gridLayer: CALayer, toAvailableSpace: Bool) {
        DockLayerFactory.scrollImageGridLayer(gridLayer, toAvailableSpace: toAvailableSpace)
    }

    func makeTextLayer(withShadow: Bool) -> CATextLayer {
        DockLayerFactory.makeTextLayer(withShadow: withShadow)
    }

    func setTextShadow(of textLayer: CATextLayer, color: CGColor, offset: CGSize, blur: CGFloat) {
        DockLayerFactory.setTextShadow(of: textLayer, color: color, offset: offset, blur: blur)
    }

    func applySelectionMaterial(to layer: CALayer) {
        DockLayerFactory.setMaterialControl(3, appearance: 1, of: layer)
    }
}

/// The Dock's uninstaller, through ``DockApplicationUninstaller``.
final class DockSpringboardUninstaller: SpringboardApplicationUninstaller {
    static let shared = DockSpringboardUninstaller()

    func canUninstall(applicationAt bundleURL: URL) -> Bool {
        DockApplicationUninstaller.canUninstall(applicationAt: bundleURL)
    }

    func uninstall(applicationAt bundleURL: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        DockApplicationUninstaller.uninstall(applicationAt: bundleURL, completion: completion)
    }
}

extension DockGlassMaterial: SpringboardGlassBackground {}

extension SpringboardRemoteTextField: SpringboardHostedTextField {}

extension SpringboardRemoteDeletionConfirmation: SpringboardHostedDeletionConfirmation {}
