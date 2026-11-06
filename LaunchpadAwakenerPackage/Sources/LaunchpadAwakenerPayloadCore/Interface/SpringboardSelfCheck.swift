import CoreGraphics
import Foundation
import ObjectiveC
import OSToolbox
import QuartzCore

#if DEBUG
/// Builds the interface once, off screen, and logs what the Dock's layer classes produced.
///
/// Nothing is put on screen. It exists so a development build can be checked from the log alone: that
/// `ECGridLayer` asked the source for its items and laid them out where 15's formulas put them, that
/// the titles are `ECShadowTextLayer`s, and what the Dock's glass is made of.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "SpringboardSelfCheck")
@MainActor
enum SpringboardSelfCheck {
    private static var hasRun = false
    /// The Dock's glass may only be asked for once the Dock is up.
    private static let glassCheckDelay: TimeInterval = 5

    static func runOnce(layout: LaunchpadLayout, metrics: SpringboardMetrics, scale: CGFloat) {
        guard !hasRun, !layout.pages.isEmpty else { return }
        hasRun = true
        let detachedRootLayer = CALayer()
        detachedRootLayer.frame = CGRect(origin: .zero, size: metrics.input.screenSize)
        let interface = SpringboardInterface(layout: layout, metrics: metrics, scale: scale, rootLayer: detachedRootLayer, showsBackground: false, applyEdit: { _ in })
        defer { interface.tearDown() }

        #log(.info, "Self-check: \(interface.geometryDescription, privacy: .public)")
        let summary = interface.firstPageSummary
        #log(.info, "Self-check: \(summary, privacy: .public)")

        DispatchQueue.main.asyncAfter(deadline: .now() + glassCheckDelay) {
            MainActor.assumeIsolated {
                checkGlassOncePerBuild(frame: detachedRootLayer.frame, scale: scale)
            }
        }
    }

    /// Asks the Dock for its glass off screen and logs the layers it made. Runs once per payload build:
    /// the marker goes down first, so a build whose call brought the Dock down is not tried again when
    /// the Dock restarts.
    private static func checkGlassOncePerBuild(frame: CGRect, scale: CGFloat) {
        let markerPath = "/tmp/LaunchpadAwakener.glass-checked-\(payloadBuildStamp)"
        guard !FileManager.default.fileExists(atPath: markerPath) else { return }
        FileManager.default.createFile(atPath: markerPath, contents: nil)
        guard DockGlassMaterial.isAvailable else {
            #log(.error, "Self-check: the Dock's glass is unavailable; the background is the stand-in blur")
            return
        }
        let background = SpringboardBackground(frame: frame, scale: scale)
        guard background.isGlass else {
            #log(.error, "Self-check: the Dock's glass could not be laid out; the background is the stand-in blur")
            return
        }
        #log(.info, "Self-check: glass, variant \(SpringboardPreferences.glassVariant, privacy: .public): \(describe(background.layer), privacy: .public)")
    }

    /// The payload executable's modification time, which changes with every build.
    private static var payloadBuildStamp: Int {
        guard
            let executablePath = Bundle(for: SpringboardGridSource.self).executablePath,
            let modificationDate = (try? FileManager.default.attributesOfItem(atPath: executablePath))?[.modificationDate] as? Date
        else { return 0 }
        return Int(modificationDate.timeIntervalSince1970)
    }

    /// The layer tree below `layer`, three levels deep: class names and frames, and for backdrops whether
    /// the window server fills them, their group and their filters.
    private static func describe(_ layer: CALayer, depth: Int = 0) -> String {
        var description = "\(String(cString: object_getClassName(layer))) \(NSStringFromRect(layer.frame))"
        if layer.responds(to: NSSelectorFromString("windowServerAware")) {
            let isWindowServerAware = (layer.value(forKey: "windowServerAware") as? Bool) ?? false
            let groupName = (layer.value(forKey: "groupName") as? String) ?? "none"
            let filterNames = (layer.filters ?? []).compactMap { ($0 as? NSObject)?.value(forKey: "name") as? String }
            description += " windowServerAware \(isWindowServerAware) group \(groupName) filters \(filterNames)"
        }
        guard depth < 3, let sublayers = layer.sublayers, !sublayers.isEmpty else { return description }
        return description + " [" + sublayers.map { describe($0, depth: depth + 1) }.joined(separator: ", ") + "]"
    }
}
#endif
