import CoreGraphics
import Foundation
import ObjectiveC
import OSToolbox
import QuartzCore

#if DEBUG
/// Builds the interface once, off screen, and logs what the Dock's layer classes produced.
///
/// Nothing is put on screen. It exists so a development build can be checked from the log alone: that
/// `ECGridLayer` asked the source for its items and laid them out where 15's formulas put them, and that
/// the titles are `ECShadowTextLayer`s.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "SpringboardSelfCheck")
@MainActor
enum SpringboardSelfCheck {
    private static var hasRun = false

    static func runOnce(layout: LaunchpadLayout, metrics: SpringboardMetrics, scale: CGFloat) {
        guard !hasRun, !layout.pages.isEmpty else { return }
        hasRun = true
        let detachedRootLayer = CALayer()
        detachedRootLayer.frame = CGRect(origin: .zero, size: metrics.input.screenSize)
        let interface = SpringboardInterface(layout: layout, metrics: metrics, scale: scale, rootLayer: detachedRootLayer, applyEdit: { _ in })
        defer { interface.tearDown() }

        #log(.info, "Self-check: \(interface.geometryDescription, privacy: .public)")
        let summary = interface.firstPageSummary
        #log(.info, "Self-check: \(summary, privacy: .public)")

        // Only the size is logged; the image stays in the Dock.
        let captureStartDate = Date()
        let wallpaperImage = WallpaperSnapshot.captureWallpaperImage(onDisplay: CGMainDisplayID())
        let captureMilliseconds = Int(Date().timeIntervalSince(captureStartDate) * 1000)
        if let wallpaperImage {
            #log(.info, "Self-check: wallpaper captured, \(wallpaperImage.width, privacy: .public)×\(wallpaperImage.height, privacy: .public) pixels in \(captureMilliseconds, privacy: .public) ms; background filters \(QuartzCorePrivate.desktopBackgroundFilters()?.count ?? 0, privacy: .public)")
        } else {
            #log(.error, "Self-check: no wallpaper captured after \(captureMilliseconds, privacy: .public) ms; the background falls back to 15's gradient")
        }
    }
}
#endif
