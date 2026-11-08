import CoreGraphics
import Foundation
import QuartzCore

// The Dock's `EC*` layer classes, written again in plain Core Animation for a process that is not the
// Dock. Every rule below — rounding, ordering, which properties are set and which are left alone — is
// taken from the 27.2 Dock as `/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md` sections 1 and 5 record it,
// so that the springboard draws the same pixels with either set. None of these layers opens a
// transaction: whether a change animates is the caller's transaction's business, as with the Dock's.

// MARK: - Layer factory

/// The springboard's layers without the Dock: the replicas below.
package struct ReplicaSpringboardLayerFactory: SpringboardLayerFactory {
    package init() {}

    package func makePageGridLayer(source: SpringboardGridSource, rowCount: Int, columnCount: Int, scaleFactor: Float) -> CALayer? {
        SpringboardReplicaPageGridLayer(source: source, rowCount: rowCount, columnCount: columnCount, scaleFactor: scaleFactor)
    }

    package func layoutPageGridLayer(_ gridLayer: CALayer) {
        (gridLayer as? SpringboardReplicaPageGridLayer)?.layout()
    }

    package func makeThumbnailGridLayer(source: SpringboardThumbnailSource, rowCount: Int, columnCount: Int, spacing: UInt, scaleFactor: Float) -> CALayer? {
        SpringboardReplicaThumbnailGridLayer(source: source, rowCount: rowCount, columnCount: columnCount, spacing: spacing, scaleFactor: scaleFactor)
    }

    package func layoutThumbnailGridLayer(_ gridLayer: CALayer) {
        (gridLayer as? SpringboardReplicaThumbnailGridLayer)?.layout()
    }

    package func invalidateThumbnailGridLayer(_ gridLayer: CALayer, source: SpringboardThumbnailSource) {
        (gridLayer as? SpringboardReplicaThumbnailGridLayer)?.invalidateContent()
    }

    package func scrollThumbnailGridLayer(_ gridLayer: CALayer, toAvailableSpace: Bool) {
        guard let thumbnailGridLayer = gridLayer as? SpringboardReplicaThumbnailGridLayer else { return }
        if toAvailableSpace {
            thumbnailGridLayer.scrollToAvailableSpace()
        } else {
            thumbnailGridLayer.scrollToTop()
        }
    }

    package func makeTextLayer(withShadow: Bool) -> CATextLayer {
        withShadow ? SpringboardReplicaShadowTextLayer() : SpringboardReplicaTextLayer()
    }

    package func setTextShadow(of textLayer: CATextLayer, color: CGColor, offset: CGSize, blur: CGFloat) {
        guard let shadowTextLayer = textLayer as? SpringboardReplicaShadowTextLayer else { return }
        shadowTextLayer.textShadowColor = color
        shadowTextLayer.textShadowOffset = offset
        shadowTextLayer.textShadowBlur = blur
    }

    package func applySelectionMaterial(to layer: CALayer) {
        let material = SpringboardReplicaMaterial.layerMaterial(control: 3, appearance: 1)
        layer.backgroundColor = material.color
        layer.compositingFilter = material.compositingFilterName
    }
}

// MARK: - Materials

/// The Dock's `-[CALayer setMaterialControl:appearance:]` (27.2 `0x1000A5328`): a grey and a plus-darker
/// or plus-lighter compositing filter, decided by the two arguments alone.
package enum SpringboardReplicaMaterial {
    /// The grey of each control, in 255ths, for the dark appearance (plus-darker) and the light one
    /// (plus-lighter): 27.2's tables at `0x100258880` and `0x1002588A0`.
    private static let plusDarkerGreys: [CGFloat] = [76, 128, 198, 232]
    private static let plusLighterGreys: [CGFloat] = [229, 124, 65, 35]

    package static func layerMaterial(control: Int, appearance: Int) -> (color: CGColor, compositingFilterName: String) {
        let isPlusDarker = appearance == 1
        let greys = isPlusDarker ? plusDarkerGreys : plusLighterGreys
        let grey = greys.indices.contains(control) ? greys[control] / 255 : 0
        // sRGB, not generic grey: the Dock builds the colour with `CGColorSpaceCreateWithName(kCGColorSpaceSRGB)`.
        let color = CGColor(srgbRed: grey, green: grey, blue: grey, alpha: 1)
        return (color, isPlusDarker ? "plusD" : "plusL")
    }
}

// MARK: - ECGridLayer

/// `ECGridLayer` made with rows and columns: cells sized from the bounds, items filled all at once and
/// placed row by row from the top left, with no spacing (ECLayerReuse.md 1.1 and 5.4).
///
/// The item count is asked for once, on creation; a page whose items change gets a new grid, as with the
/// Dock's. The source is held weakly and must be kept by the caller.
final class SpringboardReplicaPageGridLayer: CALayer {
    private weak var source: SpringboardGridSource?
    private let rowCount: Int
    private let columnCount: Int
    private let scaleFactor: Float
    /// What the source answered on creation, the only time it is asked.
    private var numberOfItems = 0
    /// Masks to the grid's bounds; its only sublayer is ``itemsLayer``.
    let clipLayer = CALayer()
    let itemsLayer = CALayer()
    /// The item layers in data order.
    private(set) var itemLayers: [CALayer] = []
    /// The items whose content was last set; content is set again only when this is not all of them.
    private var filledItemRange = NSRange(location: 0, length: 0)

    init(source: SpringboardGridSource, rowCount: Int, columnCount: Int, scaleFactor: Float) {
        self.source = source
        self.rowCount = max(rowCount, 1)
        self.columnCount = max(columnCount, 1)
        self.scaleFactor = scaleFactor
        super.init()
        clipLayer.masksToBounds = true
        addSublayer(clipLayer)
        clipLayer.addSublayer(itemsLayer)
        numberOfItems = Int(source.numberOfItems(forLayer: self))
    }

    override init(layer: Any) {
        let modelLayer = layer as? SpringboardReplicaPageGridLayer
        self.source = modelLayer?.source
        self.rowCount = modelLayer?.rowCount ?? 1
        self.columnCount = modelLayer?.columnCount ?? 1
        self.scaleFactor = modelLayer?.scaleFactor ?? 1
        super.init(layer: layer)
        numberOfItems = modelLayer?.numberOfItems ?? 0
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// `-[ECGridLayer layout]`: not `layoutSublayers`, so Core Animation never calls it by itself.
    func layout() {
        clipLayer.frame = bounds
        itemsLayer.frame = bounds
        layoutItemLayers()
    }

    private func layoutItemLayers() {
        guard let source else { return }
        let itemCount = numberOfItems
        let itemsBounds = itemsLayer.bounds
        // `(int)(height / rows)`: truncated toward zero.
        let rowHeight = CGFloat(Int(itemsBounds.height / CGFloat(rowCount)))
        let columnWidth = CGFloat(Int(itemsBounds.width / CGFloat(columnCount)))
        while itemLayers.count > itemCount {
            itemLayers.removeLast().removeFromSuperlayer()
        }
        while itemLayers.count < itemCount {
            let newLayer = source.makeLayer(forLayer: self)
            newLayer.bounds = CGRect(x: 0, y: 0, width: columnWidth, height: rowHeight)
            // Every new layer goes to the bottom, so the first item is on top.
            itemsLayer.insertSublayer(newLayer, at: 0)
            itemLayers.append(newLayer)
        }
        let allItems = NSRange(location: 0, length: itemCount)
        if filledItemRange != allItems {
            filledItemRange = allItems
            source.setContent(inLayers: itemLayers as NSArray, withDataRange: allItems, forLayer: self, usingScaleFactor: scaleFactor)
        }
        var center = CGPoint(x: columnWidth / 2, y: CGFloat(Int(itemsBounds.height)) - rowHeight / 2)
        let itemBounds = CGRect(x: 0, y: 0, width: columnWidth, height: rowHeight)
        for (itemIndex, itemLayer) in itemLayers.enumerated() {
            itemLayer.position = center
            itemLayer.bounds = itemBounds
            if (itemIndex + 1) % columnCount == 0 {
                center = CGPoint(x: columnWidth / 2, y: center.y - rowHeight)
            } else {
                center.x += columnWidth
            }
        }
    }
}

// MARK: - ECImageGridLayer

/// `ECImageGridLayer`, the grid of a folder icon's thumbnails: items in a scroll layer, each a cell less
/// the spacing, as many as the source has — more than rows × columns scroll out of sight below
/// (ECLayerReuse.md 5.1). Unlike the page grid it asks the source for the count again after
/// ``invalidateContent()``.
final class SpringboardReplicaThumbnailGridLayer: CALayer {
    private weak var source: SpringboardThumbnailSource?
    private let rowCount: Int
    private let columnCount: Int
    private let spacing: UInt
    private let scaleFactor: Float
    /// Clips by default and scrolls both ways, as `CAScrollLayer`'s defaults are; nothing else is set.
    let itemsLayer = CAScrollLayer()
    private(set) var itemLayers: [CALayer] = []
    /// nil until the source is asked, and again after an invalidation.
    private var numberOfItems: Int?
    private var filledItemRange = NSRange(location: 0, length: 0)
    private var rowHeight: CGFloat = 0
    private var columnWidth: CGFloat = 0

    init(source: SpringboardThumbnailSource, rowCount: Int, columnCount: Int, spacing: UInt, scaleFactor: Float) {
        self.source = source
        self.rowCount = max(rowCount, 1)
        self.columnCount = max(columnCount, 1)
        self.spacing = spacing
        self.scaleFactor = scaleFactor
        super.init()
        addSublayer(itemsLayer)
    }

    override init(layer: Any) {
        let modelLayer = layer as? SpringboardReplicaThumbnailGridLayer
        self.source = modelLayer?.source
        self.rowCount = modelLayer?.rowCount ?? 1
        self.columnCount = modelLayer?.columnCount ?? 1
        self.spacing = modelLayer?.spacing ?? 0
        self.scaleFactor = modelLayer?.scaleFactor ?? 1
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Moves the scroll layer half the spacing left and up — the half truncated to a whole point — then
    /// lays the items out. The scroll position is kept.
    func layout() {
        let halfSpacing = CGFloat(Int32(CGFloat(spacing) * 0.5))
        itemsLayer.frame = CGRect(x: bounds.minX - halfSpacing, y: bounds.minY + halfSpacing, width: bounds.width, height: bounds.height)
        layoutItemLayers()
    }

    /// `-layerSourceInvalidated:`: the count and every item are asked for again. The scroll position is kept.
    func invalidateContent() {
        numberOfItems = nil
        filledItemRange = NSRange(location: 0, length: 0)
        layout()
    }

    func scrollToTop() {
        itemsLayer.scroll(to: CGPoint.zero)
    }

    /// Scrolls the items up to show the slot after the last one — a whole row more when the last row is
    /// full. A grid with fewer items than cells stays where it is.
    func scrollToAvailableSpace() {
        guard let itemCount = numberOfItems else { return }
        let capacity = columnCount * rowCount
        guard itemCount >= capacity else { return }
        var extraRowCount = Int((Float(itemCount - capacity) / Float(columnCount)).rounded(.up))
        if itemCount % columnCount == 0 {
            extraRowCount += 1
        }
        itemsLayer.scroll(to: CGPoint(x: 0, y: -rowHeight * CGFloat(extraRowCount)))
    }

    private func layoutItemLayers() {
        guard let source else { return }
        let itemCount: Int
        if let numberOfItems {
            itemCount = numberOfItems
        } else {
            itemCount = Int(source.numberOfItems(forLayer: self))
            numberOfItems = itemCount
        }
        let itemsBounds = itemsLayer.bounds
        rowHeight = CGFloat(Int32(itemsBounds.height / CGFloat(rowCount)))
        columnWidth = CGFloat(Int32(itemsBounds.width / CGFloat(columnCount)))
        let spacingSide = CGFloat(spacing)
        let itemBounds = CGRect(x: 0, y: 0, width: max(columnWidth - spacingSide, 0), height: max(rowHeight - spacingSide, 0))
        while itemLayers.count > itemCount {
            itemLayers.removeLast().removeFromSuperlayer()
        }
        while itemLayers.count < itemCount {
            let newLayer = source.makeLayer(forLayer: self)
            itemLayers.append(newLayer)
            newLayer.bounds = itemBounds
            itemsLayer.insertSublayer(newLayer, at: 0)
        }
        let allItems = NSRange(location: 0, length: itemCount)
        if filledItemRange != allItems {
            filledItemRange = allItems
            if itemCount > 0 {
                source.setContent(inLayers: itemLayers as NSArray, withDataRange: allItems, forLayer: self, usingScaleFactor: scaleFactor)
            }
        }
        // The half spacing here is exact, unlike the one in `layout()`.
        let rowStartX = spacingSide / 2 + columnWidth / 2
        var center = CGPoint(x: rowStartX, y: CGFloat(Int64(itemsBounds.height)) - rowHeight / 2 - spacingSide / 2)
        for (itemIndex, itemLayer) in itemLayers.enumerated() {
            itemLayer.position = center
            itemLayer.bounds = itemBounds
            if (itemIndex + 1) % columnCount == 0 {
                center = CGPoint(x: rowStartX, y: center.y - rowHeight)
            } else {
                center.x += columnWidth
            }
        }
    }
}

// MARK: - ECTextLayer and ECShadowTextLayer

/// `ECTextLayer`: a text layer, left-aligned, that lets fonts be quantized to subpixels when it draws —
/// and sets nothing else (ECLayerReuse.md 5.3).
class SpringboardReplicaTextLayer: CATextLayer {
    override init() {
        super.init()
        alignmentMode = .left
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(in context: CGContext) {
        context.setAllowsFontSubpixelQuantization(true)
        super.draw(in: context)
    }
}

/// `ECShadowTextLayer`: the shadow is drawn with the text, its offset and blur — stored in points —
/// scaled by the contents scale, times 0.6 on a Retina display (ECLayerReuse.md 5.3).
final class SpringboardReplicaShadowTextLayer: SpringboardReplicaTextLayer {
    /// Opaque black in generic grey, as `CGColorCreateGenericGray(0, 1)` makes it, unless set.
    var textShadowColor: CGColor? = CGColor(gray: 0, alpha: 1)
    /// Stored without redrawing, as the Dock's setters store it.
    var textShadowOffset = CGSize(width: 0, height: 1)
    var textShadowBlur: CGFloat = 0
    var textShadowHidden = false {
        didSet {
            guard textShadowHidden != oldValue else { return }
            setNeedsDisplay()
        }
    }

    override init() {
        super.init()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        guard let modelLayer = layer as? SpringboardReplicaShadowTextLayer else { return }
        textShadowColor = modelLayer.textShadowColor
        textShadowOffset = modelLayer.textShadowOffset
        textShadowBlur = modelLayer.textShadowBlur
        textShadowHidden = modelLayer.textShadowHidden
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// How many device pixels the shadow moves and blurs per point: the contents scale, times 0.6 above 1.
    static func shadowScale(forContentsScale contentsScale: CGFloat) -> CGFloat {
        contentsScale > 1 ? contentsScale * 0.6 : contentsScale
    }

    override func draw(in context: CGContext) {
        if !textShadowHidden, let textShadowColor {
            let shadowScale = Self.shadowScale(forContentsScale: contentsScale)
            context.setShadow(
                offset: CGSize(width: textShadowOffset.width * shadowScale, height: textShadowOffset.height * shadowScale),
                blur: textShadowBlur * shadowScale,
                color: textShadowColor
            )
        }
        super.draw(in: context)
    }
}
