import CoreGraphics
import Foundation
import QuartzCore

/// Feeds one page to the Dock's `ECGridLayer`; the counterpart of macOS 15's `ECSBPage` as a layer source.
///
/// The grid asks for the item count once, when it is created, then calls `makeLayerForLayer:` for each
/// item and `setContentInLayers:withDataRange:forLayer:usingScaleFactor:` to fill them. It holds the
/// source weakly, so ``SpringboardPageGrid`` keeps it.
package final class SpringboardGridSource: NSObject {
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
    let rowCount: Int
    let columnCount: Int
    let cellSize: CGSize

    /// `rowCount` is the main grid's for pages, fewer for a small open folder.
    init?(items: [LaunchpadItem], metrics: SpringboardMetrics, rowCount: Int, scale: CGFloat, itemLayerWasFilled: @escaping (SpringboardItemLayer) -> Void) {
        let source = SpringboardGridSource(items: items, metrics: metrics, scale: scale)
        source.itemLayerWasFilled = itemLayerWasFilled
        guard let gridLayer = SpringboardHostSystem.layerFactory.makePageGridLayer(
            source: source,
            rowCount: rowCount,
            columnCount: metrics.input.columnCount,
            scaleFactor: Float(scale)
        ) else { return nil }
        // `ECGridLayer` keeps its items in a layer inside a clipping one, its only sublayer once made; 15's
        // `ECSBGridLayer` turned the clipping off (`initWithLayerSource:scaleFactor:layoutRTL:`, 15.5
        // `0x10011DB70`), so a picture flying to or from a folder icon's thumbnail is never cut off at
        // the page's edge.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridLayer.sublayers?.forEach { $0.masksToBounds = false }
        CATransaction.commit()
        self.gridLayer = gridLayer
        self.source = source
        self.rowCount = rowCount
        self.columnCount = metrics.input.columnCount
        self.cellSize = metrics.cellSize
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
        SpringboardHostSystem.layerFactory.layoutPageGridLayer(gridLayer)
        CATransaction.commit()
    }

    /// The cell of item `itemIndex`, in the grid layer, as `ECGridLayer` lays it out: from the top left,
    /// row by row, no gaps.
    func cellFrame(at itemIndex: Int) -> CGRect {
        let row = itemIndex / columnCount
        let column = itemIndex % columnCount
        return CGRect(
            x: CGFloat(column) * cellSize.width,
            y: CGFloat(Int(gridLayer.bounds.height)) - CGFloat(row + 1) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
    }

    /// How many items the grid shows; further ones are hidden until they spill over to the next page.
    var capacity: Int {
        rowCount * columnCount
    }

    /// `point`, in the grid layer, measured from its top-left corner.
    func pointFromTopLeft(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: CGFloat(Int(gridLayer.bounds.height)) - point.y)
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
