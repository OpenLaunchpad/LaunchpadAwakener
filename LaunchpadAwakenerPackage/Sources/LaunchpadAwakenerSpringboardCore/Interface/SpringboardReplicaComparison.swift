import CoreGraphics
import CoreText
import Foundation
import QuartzCore

#if DEBUG
/// Builds the same page, folder thumbnails, selection and title with the host's layer factory and with the
/// replicas, and says where they differ: in the Dock, the host's factory is the Dock's own `EC*` classes,
/// so this is how the replicas the standalone app draws with are held to them.
@MainActor
enum SpringboardReplicaComparison {
    /// One line per check, each saying whether the replica matched; nil where the host's factory is the
    /// replicas themselves, with nothing to compare against.
    static func compare(firstPage: LaunchpadPage, metrics: SpringboardMetrics, scale: CGFloat) -> [String]? {
        let hostFactory = SpringboardHostSystem.layerFactory
        guard !(hostFactory is ReplicaSpringboardLayerFactory) else { return nil }
        let replicaFactory = ReplicaSpringboardLayerFactory()
        return [
            comparePageGrids(hostFactory: hostFactory, replicaFactory: replicaFactory, items: firstPage.items, metrics: metrics, scale: scale),
            compareThumbnailGrids(hostFactory: hostFactory, replicaFactory: replicaFactory, scale: scale),
            compareSelectionMaterials(hostFactory: hostFactory, replicaFactory: replicaFactory),
            compareTitles(hostFactory: hostFactory, replicaFactory: replicaFactory, scale: scale),
        ]
    }

    // MARK: - Grids

    private static func comparePageGrids(hostFactory: any SpringboardLayerFactory, replicaFactory: any SpringboardLayerFactory, items: [LaunchpadItem], metrics: SpringboardMetrics, scale: CGFloat) -> String {
        func itemFrames(using factory: any SpringboardLayerFactory) -> [CGRect]? {
            let source = SpringboardGridSource(items: items, metrics: metrics, scale: scale)
            guard let gridLayer = factory.makePageGridLayer(
                source: source,
                rowCount: metrics.input.rowCount,
                columnCount: metrics.input.columnCount,
                scaleFactor: Float(scale)
            ) else { return nil }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gridLayer.frame = CGRect(origin: .zero, size: metrics.pageSize)
            factory.layoutPageGridLayer(gridLayer)
            CATransaction.commit()
            return source.itemLayers.map(\.frame)
        }
        guard let hostFrames = itemFrames(using: hostFactory), let replicaFrames = itemFrames(using: replicaFactory) else {
            return "page grid: one of the two could not be made"
        }
        let differingCount = zip(hostFrames, replicaFrames).filter { $0 != $1 }.count + abs(hostFrames.count - replicaFrames.count)
        return differingCount == 0
            ? "page grid matches, \(hostFrames.count) item(s)"
            : "page grid DIFFERS in \(differingCount) of \(hostFrames.count) item(s); first host \(hostFrames.first.map(NSStringFromRect) ?? "none"), replica \(replicaFrames.first.map(NSStringFromRect) ?? "none")"
    }

    /// Twelve thumbnails in a 3 × 3 grid, laid out, then scrolled to the free slot: frames and offset.
    private static func compareThumbnailGrids(hostFactory: any SpringboardLayerFactory, replicaFactory: any SpringboardLayerFactory, scale: CGFloat) -> String {
        func thumbnailGeometry(using factory: any SpringboardLayerFactory) -> (frames: [CGRect], scrolledOrigin: CGPoint)? {
            let source = SpringboardThumbnailSource()
            source.images = Array(repeating: nil, count: 12)
            source.scale = scale
            guard let gridLayer = factory.makeThumbnailGridLayer(source: source, rowCount: 3, columnCount: 3, spacing: 4, scaleFactor: Float(scale)) else { return nil }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gridLayer.frame = CGRect(x: 0, y: 0, width: 61, height: 61)
            factory.layoutThumbnailGridLayer(gridLayer)
            factory.scrollThumbnailGridLayer(gridLayer, toAvailableSpace: true)
            CATransaction.commit()
            guard let itemsLayer = gridLayer.sublayers?.first else { return nil }
            let frames = (itemsLayer.sublayers ?? []).map { itemsLayer.convert($0.frame, to: gridLayer) }
            return (frames, itemsLayer.bounds.origin)
        }
        guard let hostGeometry = thumbnailGeometry(using: hostFactory), let replicaGeometry = thumbnailGeometry(using: replicaFactory) else {
            return "thumbnails: one of the two could not be made"
        }
        guard hostGeometry.frames == replicaGeometry.frames, hostGeometry.scrolledOrigin == replicaGeometry.scrolledOrigin else {
            return "thumbnails DIFFER: host \(hostGeometry.frames.count) at \(hostGeometry.frames.last.map(NSStringFromRect) ?? "none") scrolled to \(NSStringFromPoint(hostGeometry.scrolledOrigin)), replica \(replicaGeometry.frames.count) at \(replicaGeometry.frames.last.map(NSStringFromRect) ?? "none") scrolled to \(NSStringFromPoint(replicaGeometry.scrolledOrigin))"
        }
        return "thumbnails match, \(hostGeometry.frames.count) scrolled to \(NSStringFromPoint(hostGeometry.scrolledOrigin))"
    }

    // MARK: - Selection

    private static func compareSelectionMaterials(hostFactory: any SpringboardLayerFactory, replicaFactory: any SpringboardLayerFactory) -> String {
        let hostLayer = CALayer()
        let replicaLayer = CALayer()
        hostFactory.applySelectionMaterial(to: hostLayer)
        replicaFactory.applySelectionMaterial(to: replicaLayer)
        let hostDescription = describeMaterial(of: hostLayer)
        let replicaDescription = describeMaterial(of: replicaLayer)
        return hostDescription == replicaDescription
            ? "selection material matches: \(hostDescription)"
            : "selection material DIFFERS: host \(hostDescription), replica \(replicaDescription)"
    }

    private static func describeMaterial(of layer: CALayer) -> String {
        let components = layer.backgroundColor?.components?.map { String(format: "%.4f", Double($0)) }.joined(separator: " ") ?? "none"
        let colorSpaceName = (layer.backgroundColor?.colorSpace?.name as String?) ?? "none"
        return "\(colorSpaceName) [\(components)] \(String(describing: layer.compositingFilter ?? "no filter"))"
    }

    // MARK: - Titles

    /// The same title with its shadow, drawn by each layer's own drawing code into a grey bitmap at the
    /// display's scale, the way Core Animation fills a layer's backing store.
    private static func compareTitles(hostFactory: any SpringboardLayerFactory, replicaFactory: any SpringboardLayerFactory, scale: CGFloat) -> String {
        let size = CGSize(width: 160, height: 22)
        func titlePixels(using factory: any SpringboardLayerFactory) -> [UInt8]? {
            let textLayer = factory.makeTextLayer(withShadow: true)
            textLayer.font = SpringboardTypography.labelFont
            textLayer.fontSize = CTFontGetSize(SpringboardTypography.labelFont)
            textLayer.foregroundColor = CGColor(gray: 1, alpha: 1)
            textLayer.truncationMode = .middle
            textLayer.alignmentMode = .center
            textLayer.contentsScale = scale
            textLayer.string = "实用工具 Launchpad"
            textLayer.bounds = CGRect(origin: .zero, size: size)
            factory.setTextShadow(of: textLayer, color: CGColor(gray: 0, alpha: 0.2), offset: CGSize(width: 0, height: -1), blur: 2)
            let pixelWidth = Int(size.width * scale)
            let pixelHeight = Int(size.height * scale)
            guard
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: pixelWidth * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            context.scaleBy(x: scale, y: scale)
            textLayer.draw(in: context)
            guard let data = context.data else { return nil }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: pixelWidth * pixelHeight * 4))
        }
        guard let hostPixels = titlePixels(using: hostFactory), let replicaPixels = titlePixels(using: replicaFactory) else {
            return "title: one of the two could not be drawn"
        }
        let largestDifference = zip(hostPixels, replicaPixels).map { abs(Int($0) - Int($1)) }.max() ?? 0
        let differingByteCount = zip(hostPixels, replicaPixels).filter { $0 != $1 }.count
        return largestDifference == 0
            ? "title pixels match, \(hostPixels.count / 4) pixel(s)"
            : "title pixels DIFFER in \(differingByteCount) byte(s), by up to \(largestDifference)/255"
    }
}
#endif
