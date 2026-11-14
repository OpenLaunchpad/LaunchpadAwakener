import CoreGraphics
import Foundation
import ImageIO
import OSToolbox

/// Wraps a value that is only ever touched by one thread at a time but cannot say so to the compiler.
package struct UncheckedSendableBox<Value>: @unchecked Sendable {
    package let value: Value

    package init(value: Value) {
        self.value = value
    }
}

/// Application icons in the Dock's current icon style, rendered off the main thread and kept.
///
/// macOS 15 cached rendered icons in its database; macOS 27 icons follow the user's icon style, so
/// they are rendered here instead and cached per style. Until an icon is ready, the icon macOS 15
/// cached stands in for it.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "SpringboardIconProvider")
@MainActor
final class SpringboardIconProvider {
    static let shared = SpringboardIconProvider()

    private struct CacheKey: Hashable {
        let bundlePath: String
        let pixelSide: Int
        let style: UInt8
    }

    private let renderQueue = DispatchQueue(label: "com.MxIris.LaunchpadAwakener.IconRendering", qos: .userInitiated)
    private var images: [CacheKey: CGImage] = [:]
    private var pendingKeys: Set<CacheKey> = []
    private var prefetchStartDate: Date?
    private var renderFailureCount = 0
    private var currentStyle: UInt8 = 0
    /// The Dock's descriptor for the current style, copied for every icon.
    private var iconDescriptorTemplate: NSObject?

    /// Called when an icon that was missing becomes available, with the bundle it belongs to.
    var iconDidBecomeAvailable: ((URL) -> Void)?

    /// The compositing filter the Dock gives icons in the current style; nil for the default style.
    private(set) var glassCompositingFilterName: String?

    /// Reads the host's icon style; call before a batch of requests, such as on every show.
    func refreshIconStyle() {
        let iconStyle = SpringboardHostSystem.host.iconStyle
        if let iconStyle, iconStyle.style != currentStyle {
            #log(.info, "Icon style is now \(iconStyle.style, privacy: .public)")
        }
        currentStyle = iconStyle?.style ?? 0
        iconDescriptorTemplate = iconStyle?.iconDescriptor
        glassCompositingFilterName = iconStyle?.glassCompositingFilterName
    }

    /// The icon, if it is ready; otherwise starts rendering it and returns nil.
    func icon(forApplicationAt bundleURL: URL, pointSide: CGFloat, scale: CGFloat) -> CGImage? {
        let cacheKey = CacheKey(bundlePath: bundleURL.path, pixelSide: Int((pointSide * scale).rounded()), style: currentStyle)
        if let image = images[cacheKey] {
            return image
        }
        render(cacheKey, bundleURL: bundleURL, pointSide: pointSide, scale: scale)
        return nil
    }

    /// Renders icons ahead of the first showing.
    func prefetchIcons(forApplicationsAt bundleURLs: [URL], pointSide: CGFloat, scale: CGFloat) {
        let pendingCountBefore = pendingKeys.count
        for bundleURL in bundleURLs {
            _ = icon(forApplicationAt: bundleURL, pointSide: pointSide, scale: scale)
        }
        if pendingKeys.count > pendingCountBefore, prefetchStartDate == nil {
            prefetchStartDate = Date()
            renderFailureCount = 0
        }
    }

    private func render(_ cacheKey: CacheKey, bundleURL: URL, pointSide: CGFloat, scale: CGFloat) {
        guard pendingKeys.insert(cacheKey).inserted else { return }
        guard let descriptor = IconServicesBridge.makeDescriptor(copying: iconDescriptorTemplate, pointSize: pointSide, scale: scale) else {
            pendingKeys.remove(cacheKey)
            return
        }
        let descriptorBox = UncheckedSendableBox(value: descriptor)
        renderQueue.async {
            let image = IconServicesBridge.makeIconImage(forFileAt: bundleURL, descriptor: descriptorBox.value)
            let imageBox = UncheckedSendableBox(value: image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let provider = SpringboardIconProvider.shared
                    provider.pendingKeys.remove(cacheKey)
                    if let renderedImage = imageBox.value {
                        provider.images[cacheKey] = renderedImage
                        provider.iconDidBecomeAvailable?(bundleURL)
                    } else {
                        provider.renderFailureCount += 1
                        provider.logFailure(for: bundleURL)
                    }
                    provider.logPrefetchCompletionIfDone()
                }
            }
        }
    }

    private func logPrefetchCompletionIfDone() {
        guard pendingKeys.isEmpty, let prefetchStartDate else { return }
        self.prefetchStartDate = nil
        #log(.info, "Icons ready: \(self.images.count, privacy: .public) cached, \(self.renderFailureCount, privacy: .public) failed, \(String(format: "%.2f", Date().timeIntervalSince(prefetchStartDate)), privacy: .public) s")
    }

    private func logFailure(for bundleURL: URL) {
        #log(.error, "No icon for \(bundleURL.path, privacy: .public)")
    }

    /// The 256-point PNG macOS 15 cached, decoded.
    static func legacyIcon(from pngData: Data?) -> CGImage? {
        guard let pngData, let imageSource = CGImageSourceCreateWithData(pngData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }
}
