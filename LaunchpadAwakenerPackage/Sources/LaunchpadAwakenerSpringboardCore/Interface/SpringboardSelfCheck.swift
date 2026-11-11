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

    static func runOnce(layout: LaunchpadLayout, metrics: SpringboardMetrics, scale: CGFloat, displayIdentifier: CGDirectDisplayID) {
        guard !hasRun, !layout.pages.isEmpty else { return }
        hasRun = true
        logDisplays(showingOn: displayIdentifier)
        let detachedRootLayer = CALayer()
        detachedRootLayer.frame = CGRect(origin: .zero, size: metrics.input.screenSize)
        let interface = SpringboardInterface(layout: layout, metrics: metrics, scale: scale, rootLayer: detachedRootLayer, backgroundStyle: nil, applyEdit: { _ in })
        defer { interface.tearDown() }

        #log(.info, "Self-check: \(interface.geometryDescription, privacy: .public)")
        let summary = interface.firstPageSummary
        #log(.info, "Self-check: \(summary, privacy: .public)")
        if let firstPage = layout.pages.first, let comparisons = SpringboardReplicaComparison.compare(firstPage: firstPage, metrics: metrics, scale: scale) {
            for comparison in comparisons {
                #log(.info, "Self-check: replica \(comparison, privacy: .public)")
            }
        }
        // Asks only; nothing is deleted.
        let host = SpringboardHostSystem.host
        if let uninstaller = host.applicationUninstaller {
            let deletableTitles = layout.applications.filter { application in
                application.bundleURL.map(uninstaller.canUninstall(applicationAt:)) ?? false
            }.map(\.title)
            #log(.info, "Self-check: the Dock's uninstaller would delete \(deletableTitles.count, privacy: .public) of \(layout.applications.count, privacy: .public) application(s): \(deletableTitles.prefix(5).joined(separator: ", "), privacy: .public)")
        } else {
            #log(.error, "Self-check: the Dock's uninstaller is out of reach; no close boxes")
        }
        let recentlyAddedTitles = layout.applications.filter(\.isRecentlyAdded).map(\.title)
        #log(.info, "Self-check: \(recentlyAddedTitles.count, privacy: .public) application(s) marked new: \(recentlyAddedTitles.prefix(5).joined(separator: ", "), privacy: .public)")
        if let resourceBundle = host.resourceBundle {
            let searchFieldImageNames = ["ectl_search_background", "ectl_search_loupe", "ectl_search_close"]
            let foundImageCount = searchFieldImageNames.count { imageName in
                SpringboardTextures.image(named: imageName, scale: scale, in: resourceBundle) != nil
            }
            #log(.info, "Self-check: resources from \(resourceBundle.bundlePath, privacy: .public), language \(SpringboardLocalization.preferredLocalizations.first ?? "none", privacy: .public) (\"\(SpringboardStrings.search, privacy: .public)\"), \(foundImageCount, privacy: .public) of \(searchFieldImageNames.count, privacy: .public) search field image(s)")
        } else {
            #log(.error, "Self-check: no resource bundle; the search field has no images and the words are English")
        }

        // Only the size is logged; the image stays in the Dock.
        let captureStartDate = Date()
        let wallpaperImage = host.wallpaperImage(onDisplay: displayIdentifier)
        let captureMilliseconds = Int(Date().timeIntervalSince(captureStartDate) * 1000)
        if let wallpaperImage {
            #log(.info, "Self-check: wallpaper captured, \(wallpaperImage.width, privacy: .public)×\(wallpaperImage.height, privacy: .public) pixels in \(captureMilliseconds, privacy: .public) ms; background filters \(QuartzCorePrivate.desktopBackgroundFilters()?.count ?? 0, privacy: .public)")
        } else {
            #log(.error, "Self-check: no wallpaper captured after \(captureMilliseconds, privacy: .public) ms; the background falls back to 15's gradient")
        }

        guard host.offersGlassBackground else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + glassCheckDelay) {
            MainActor.assumeIsolated {
                checkGlassOncePerBuild(frame: detachedRootLayer.frame, scale: scale)
            }
        }
    }

    /// Every display the springboard could open on, where the host says the Dock is, and the display chosen.
    private static func logDisplays(showingOn displayIdentifier: CGDirectDisplayID) {
        let displayDescriptions = SpringboardDisplay.activeDisplays.map { activeDisplay in
            let bounds = CGDisplayBounds(activeDisplay)
            let scale = SpringboardDisplay.backingScaleFactor(of: activeDisplay)
            let mainMark = CGDisplayIsMain(activeDisplay) != 0 ? " main" : ""
            return "\(activeDisplay)\(mainMark) \(Int(bounds.width))×\(Int(bounds.height)) at (\(Int(bounds.minX)), \(Int(bounds.minY))) scale \(scale)"
        }
        let dockDisplayDescription = SpringboardHostSystem.host.dockDisplayIdentifier.map { "display \($0)" } ?? "an unknown display"
        #log(.info, "Self-check: displays \(displayDescriptions.joined(separator: "; "), privacy: .public); the Dock is on \(dockDisplayDescription, privacy: .public), the springboard opens on display \(displayIdentifier, privacy: .public)")
    }

    /// Asks the Dock for its glass off screen and logs the layers it made. Runs once per payload build:
    /// the marker goes down first, so a build whose call brought the Dock down is not tried again when
    /// the Dock restarts.
    private static func checkGlassOncePerBuild(frame: CGRect, scale: CGFloat) {
        let markerPath = "/tmp/LaunchpadAwakener.glass-checked-\(payloadBuildStamp)"
        guard !FileManager.default.fileExists(atPath: markerPath) else { return }
        FileManager.default.createFile(atPath: markerPath, contents: nil)
        let background = SpringboardBackground(style: .glass, frame: frame, scale: scale, wallpaperImage: nil)
        guard background.isGlass else {
            #log(.error, "Self-check: the Dock's glass is unavailable or could not be laid out; the background is the stand-in blur")
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

    /// Logs the background of a springboard as it is shown, in full: what the glass looks like on screen
    /// cannot be read back, but how its layers are set up can.
    static func logShownBackground(of interface: SpringboardInterface, rootLayer: CALayer) {
        guard let background = interface.background else { return }
        #log(.info, "Shown background: root flipped \(rootLayer.isGeometryFlipped, privacy: .public) contents flipped \(rootLayer.contentsAreFlipped(), privacy: .public); container flipped \(interface.containerLayer.isGeometryFlipped, privacy: .public)")
        for line in describeLines(background.layer, depth: 0, maximumDepth: 8) {
            #log(.info, "Shown background: \(line, privacy: .public)")
        }
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

    /// One line per layer, indented by depth, with every property that decides what the glass draws.
    private static func describeLines(_ layer: CALayer, depth: Int, maximumDepth: Int) -> [String] {
        let className = String(cString: object_getClassName(layer))
        var line = String(repeating: "  ", count: depth) + "\(className) frame \(NSStringFromRect(layer.frame)) bounds \(NSStringFromRect(layer.bounds))"
        line += " opacity \(layer.opacity) hidden \(layer.isHidden) masks \(layer.masksToBounds) flipped \(layer.isGeometryFlipped) scale \(layer.contentsScale)"
        if !CATransform3DIsIdentity(layer.transform) {
            line += " transform \(layer.transform.m11)x\(layer.transform.m22)"
        }
        if let mask = layer.mask {
            line += " mask \(String(cString: object_getClassName(mask))) \(NSStringFromRect(mask.frame))"
        }
        if let filters = layer.filters, !filters.isEmpty {
            line += " filters \(filters.compactMap { ($0 as? NSObject)?.value(forKey: "name") as? String })"
        }
        if layer.compositingFilter != nil {
            line += " compositing \(String(describing: layer.compositingFilter))"
        }
        let propertyNames: [String] = switch className {
        case "CABackdropLayer":
            ["enabled", "windowServerAware", "groupName", "scale", "backdropRect", "marginWidth", "sourceSublayerDefinesBounds", "ignoresScreenClip", "captureOnly", "preallocatesScreenArea", "bleedAmount", "zoom", "ignoresOffscreenGroups", "allowsInPlaceFiltering"]
        case "CASDFLayer":
            ["effect", "smoothness", "gaussianRadius", "effectOffset", "mergeElements", "experimentalCulling"]
        case "CASDFElementLayer":
            ["mode", "operation", "cornerRadius", "contentsZeroValueDistance", "contentsOneValueDistance", "gradientOvalization"]
        case "CAPortalLayer":
            ["sourceLayer", "sourceLayerRenderId", "hidesSourceLayer", "matchesPosition", "matchesTransform", "matchesOpacity", "allowsBackdropGroups", "crossDisplay"]
        default:
            []
        }
        for propertyName in propertyNames where layer.responds(to: NSSelectorFromString(propertyName)) || propertyName == "enabled" {
            let value = layer.value(forKey: propertyName)
            let valueDescription = (value as? CALayer).map { "\(String(cString: object_getClassName($0))) \(NSStringFromRect($0.frame))" } ?? String(describing: value ?? "nil")
            line += " \(propertyName) \(valueDescription)"
        }
        var lines = [line]
        guard depth < maximumDepth else { return lines }
        for sublayer in layer.sublayers ?? [] {
            lines += describeLines(sublayer, depth: depth + 1, maximumDepth: maximumDepth)
        }
        return lines
    }
}
#endif
