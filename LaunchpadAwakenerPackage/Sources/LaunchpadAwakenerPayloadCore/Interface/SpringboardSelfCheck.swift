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
    }
}
#endif
