import CoreGraphics
import Foundation
import QuartzCore

/// Feeds one page to the Dock's `ECGridLayer`; the counterpart of macOS 15's `ECSBPage` as a layer source.
///
/// The grid asks for the item count once, when it is created, then calls `makeLayerForLayer:` for each
/// item and `setContentInLayers:withDataRange:forLayer:usingScaleFactor:` to fill them. It holds the
/// source weakly, so ``SpringboardPageGrid`` keeps it.
final class SpringboardGridSource: NSObject {
    let items: [LaunchpadItem]
    private let metrics: SpringboardMetrics
    private let scale: CGFloat
    /// The item layers in data order, as the grid last filled them.
    private(set) var itemLayers: [SpringboardItemLayer] = []
    /// Called for each item layer the grid fills, so its icons can be put in.
    var itemLayerWasFilled: ((SpringboardItemLayer) -> Void)?

    init(items: [LaunchpadItem], metrics: SpringboardMetrics, scale: CGFloat) {
        self.items = items
        self.metrics = metrics
        self.scale = scale
    }

    @objc(numberOfItemsForLayer:)
    func numberOfItems(forLayer gridLayer: CALayer) -> UInt {
        UInt(items.count)
    }

    @objc(makeLayerForLayer:)
    func makeLayer(forLayer gridLayer: CALayer) -> CALayer {
        SpringboardItemLayer()
    }

    @objc(setContentInLayers:withDataRange:forLayer:usingScaleFactor:)
    func setContent(inLayers layers: NSArray, withDataRange dataRange: NSRange, forLayer gridLayer: CALayer, usingScaleFactor scaleFactor: Float) {
        var filledLayers: [SpringboardItemLayer] = []
        for (offset, layer) in layers.enumerated() {
            let itemIndex = dataRange.location + offset
            guard let itemLayer = layer as? SpringboardItemLayer, items.indices.contains(itemIndex) else { continue }
            itemLayer.configure(with: items[itemIndex], metrics: metrics, scale: scale)
            filledLayers.append(itemLayer)
            itemLayerWasFilled?(itemLayer)
        }
        // `ECGridLayer` always fills every item at once, from the first.
        if dataRange.location == 0 {
            itemLayers = filledLayers
        }
    }
}

/// One page of icons on the Dock's `ECGridLayer`, as macOS 15's `ECSBGridLayer` was one.
///
/// The grid sizes its cells from its bounds and lays the items out from the top left without gaps,
/// exactly as `-[ECSBGridLayer _layoutItemLayers]` did. It never learns of a new item count, so a page
/// whose items change gets a new grid.
@MainActor
final class SpringboardPageGrid {
    let gridLayer: CALayer
    let source: SpringboardGridSource

    init?(items: [LaunchpadItem], metrics: SpringboardMetrics, scale: CGFloat, itemLayerWasFilled: @escaping (SpringboardItemLayer) -> Void) {
        let source = SpringboardGridSource(items: items, metrics: metrics, scale: scale)
        source.itemLayerWasFilled = itemLayerWasFilled
        guard let gridLayer = DockLayerFactory.makeGridLayer(
            source: source,
            rowCount: metrics.input.rowCount,
            columnCount: metrics.input.columnCount,
            scaleFactor: Float(scale)
        ) else { return nil }
        self.gridLayer = gridLayer
        self.source = source
    }

    var items: [LaunchpadItem] {
        source.items
    }

    var itemLayers: [SpringboardItemLayer] {
        source.itemLayers
    }

    /// Places the grid and has it lay out and fill its items. `centeredRowOffset` moves a single short
    /// row of search results to the middle, as 15's `centerSingleRow` did.
    func layout(in pageFrame: CGRect, centeredRowOffset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridLayer.frame = pageFrame.offsetBy(dx: centeredRowOffset, dy: 0)
        DockLayerFactory.layoutGridLayer(gridLayer)
        CATransaction.commit()
    }

    /// The item under `point`, a point in the grid layer, and whether it is on the item's icon.
    func item(at point: CGPoint) -> (index: Int, itemLayer: SpringboardItemLayer, isOnIcon: Bool)? {
        for (itemIndex, itemLayer) in itemLayers.enumerated() where itemLayer.frame.contains(point) {
            let pointInItem = CGPoint(x: point.x - itemLayer.frame.minX, y: point.y - itemLayer.frame.minY)
            return (itemIndex, itemLayer, itemLayer.iconFrame.contains(pointInItem))
        }
        return nil
    }
}
