import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// An open folder; macOS 15's `ECSBGroupLayer`.
///
/// A rounded panel of white 97 % at half opacity, corner radius 36, holding the folder's pages on the
/// Dock's `ECGridLayer`, its own page dots, and the title above it in Light 28
/// (`-[ECSBGroupLayer initWithGroup:groupPager:layoutRTL:]`, 15.5 `0x10004BE70`). Opening grows the
/// panel out of the folder icon's square while the pictures fly out of its thumbnails into their cells;
/// closing reverses it (`animatedShow` `0x10004E0E4`, `animatedHide` `0x10004E63C`), each in one
/// transaction of default 0.25 s implicit animations.
///
/// The panel only tints what lies behind it. 15 made it a `CABackdropLayer` and gave it a blur of 30 and
/// a saturation of 1.8, but as `backgroundFilters`, which a backdrop does not apply: macOS 15.5 shows the
/// main grid sharp through the panel while it fades out behind it, only washed by the white. Its
/// "frosting" is the blurred wallpaper behind it.
@MainActor
final class SpringboardFolderPanel {
    static let animationDuration: CFTimeInterval = 0.25

    private(set) var folder: LaunchpadFolder
    let folderMetrics: SpringboardFolderMetrics
    let pages: SpringboardPagedGrids
    /// Shares the springboard layer's coordinate space.
    let folderLayer = CALayer()
    private let maskContainerLayer = CALayer()
    private let maskLayer = CALayer()
    /// The panel's white, as it grows and shrinks.
    private let tintLayer = CALayer()
    let titleLayer = SpringboardLabelLayer(font: SpringboardTypography.folderTitleFont)
    let titleEditorLayer = SpringboardTitleEditorLayer()
    private let scale: CGFloat

    init(
        folder: LaunchpadFolder,
        metrics: SpringboardMetrics,
        scale: CGFloat,
        itemLayerWasFilled: @escaping (SpringboardItemLayer) -> Void
    ) {
        self.folder = folder
        self.scale = scale
        let folderMetrics = SpringboardFolderMetrics(metrics: metrics, applicationCount: folder.applications.count, isDragging: false)
        self.folderMetrics = folderMetrics
        pages = SpringboardPagedGrids(
            metrics: metrics,
            scale: scale,
            pageStride: folderMetrics.folderFrame.width,
            pageFrame: { folderMetrics.pageFrame(at: $0) }
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        folderLayer.frame = folderMetrics.folderFrame
        folderLayer.masksToBounds = false
        folderLayer.allowsGroupOpacity = false
        maskContainerLayer.frame = folderLayer.bounds
        maskContainerLayer.mask = maskLayer
        maskLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
        maskLayer.cornerCurve = .continuous
        tintLayer.backgroundColor = SpringboardItemLayer.folderBackdropColor
        tintLayer.cornerCurve = .continuous
        for panelLayer in [tintLayer, maskLayer] {
            panelLayer.frame = folderMetrics.panelFrame
            panelLayer.cornerRadius = SpringboardFolderMetrics.panelCornerRadius
        }
        pages.scrollLayer.frame = folderMetrics.scrollFrame
        pages.pagerControlLayer.frame = folderMetrics.pagerControlFrame
        maskContainerLayer.addSublayer(tintLayer)
        maskContainerLayer.addSublayer(pages.scrollLayer)
        maskContainerLayer.addSublayer(pages.pagerControlLayer)
        folderLayer.addSublayer(maskContainerLayer)

        titleLayer.setString(folder.title, contentsScale: scale)
        titleLayer.frame = folderMetrics.titleFrame(forTitleSize: titleLayer.preferredSize)
        titleEditorLayer.configure(scale: scale)
        titleEditorLayer.frame = titleEditingFrame
        titleEditorLayer.isHidden = true
        folderLayer.addSublayer(titleLayer)
        folderLayer.addSublayer(titleEditorLayer)
        CATransaction.commit()

        showPages(itemLayerWasFilled: itemLayerWasFilled, pageIndex: 0)
    }

    private func showPages(itemLayerWasFilled: @escaping (SpringboardItemLayer) -> Void, pageIndex: Int) {
        pages.showPages(
            folder.pages.map { $0.applications.map(LaunchpadItem.application) },
            rowCount: folderMetrics.rowCount,
            pageIndex: pageIndex,
            itemLayerWasFilled: itemLayerWasFilled
        )
    }

    /// Takes the folder as stored now, after an edit; keeps the page shown.
    func update(with newFolder: LaunchpadFolder, itemLayerWasFilled: @escaping (SpringboardItemLayer) -> Void) {
        let isContentChanged = newFolder.pages != folder.pages
        folder = newFolder
        setTitle(newFolder.title)
        if isContentChanged {
            showPages(itemLayerWasFilled: itemLayerWasFilled, pageIndex: pages.currentPageIndex)
        }
    }

    /// Rebuilds the pages from the folder as it is, on `pageIndex`.
    func reloadPages(pageIndex: Int, itemLayerWasFilled: @escaping (SpringboardItemLayer) -> Void) {
        showPages(itemLayerWasFilled: itemLayerWasFilled, pageIndex: pageIndex)
    }

    func setTitle(_ title: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.setString(title, contentsScale: scale)
        titleLayer.frame = folderMetrics.titleFrame(forTitleSize: titleLayer.preferredSize)
        titleEditorLayer.frame = titleEditingFrame
        CATransaction.commit()
    }

    /// Where a click starts renaming: the title, widened by 200 points on each side (15's `labelEditLayer`).
    var titleEditingFrame: CGRect {
        titleLayer.frame.insetBy(dx: -SpringboardFolderMetrics.titleEditingOutset, dy: 0)
    }

    // MARK: - Hit testing, in the folder layer's superlayer

    func pointInFolder(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - folderLayer.frame.minX, y: point.y - folderLayer.frame.minY)
    }

    func isInsidePanel(_ point: CGPoint) -> Bool {
        folderMetrics.panelFrame.contains(pointInFolder(point))
    }

    func isOnTitle(_ point: CGPoint) -> Bool {
        titleEditingFrame.contains(pointInFolder(point))
    }

    // MARK: - Opening and closing

    /// How many of the first page's icons a folder icon shows as thumbnails.
    static let thumbnailCount = 9

    /// Grows the panel out of `folderItemLayer`'s square while the first page's pictures fly out of its
    /// thumbnails into their cells and their titles fade in under them, as 15's `prepareForAnimatedShow`
    /// (15.5 `0x10004DECC`) and `animatedShow` (`0x10004E0E4`) did. Everything moves by implicit
    /// animations in one transaction, so the pictures keep pace with the panel. `containerLayer` is the
    /// folder layer's superlayer; `springboardLayer` fades to 0 and shrinks to 0.95 meanwhile, as 15's
    /// main grid did. With Reduce Motion the panel appears at once and the pages only fade, as in 15.
    func animateOpen(from folderItemLayer: SpringboardItemLayer, springboardLayer: CALayer, containerLayer: CALayer, completion: @escaping @MainActor () -> Void) {
        let isAnimated = !SpringboardPreferences.reducesMotion
        let backdropRect = rectInFolder(folderItemLayer.folderBackdropFrame, of: folderItemLayer, springboardLayer: springboardLayer)
        let folderCellRect = rectInFolder(folderItemLayer.bounds, of: folderItemLayer, springboardLayer: springboardLayer)
        let thumbnailGridRect = rectInFolder(folderItemLayer.thumbnailGridFrame, of: folderItemLayer, springboardLayer: springboardLayer)
        let firstPageItemLayers = pages.pageGrids.first?.itemLayers ?? []
        let titleFrame = titleLayer.frame
        let scrollPosition = pages.scrollLayer.position
        // The grid has placed its items; lay them out now, so that the titles have their sizes.
        firstPageItemLayers.forEach { $0.layoutIfNeeded() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.addSublayer(folderLayer)
        if isAnimated {
            for panelLayer in [tintLayer, maskLayer] {
                panelLayer.frame = backdropRect
                panelLayer.cornerRadius = folderItemLayer.folderCornerRadius
            }
            titleLayer.frame = Self.titleFrameOverFolder(cellRect: folderCellRect, titleSize: titleFrame.size)
            titleLayer.opacity = 0
            // 15's pages hung from a container shrunk onto the folder's cell, by its bottom left corner,
            // and came out with it.
            pages.scrollLayer.position = CGPoint(x: scrollPosition.x + folderCellRect.minX, y: scrollPosition.y + folderCellRect.minY)
            minimize(firstPageItemLayers, intoThumbnailGrid: thumbnailGridRect)
        }
        pages.pagerControlLayer.opacity = 0
        folderItemLayer.opacity = 0
        CATransaction.commit()
        // Core Animation does not animate a change to a layer it has never committed, and every layer
        // of the panel is new: put the starting state on screen first.
        CATransaction.flush()

        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.animationDuration)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.1)
                self.pages.pagerControlLayer.opacity = 1
                CATransaction.commit()
                // The pictures are full size and in place again; 15's `_removeItemLayerFilters`.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for itemLayer in firstPageItemLayers {
                    itemLayer.imageLayer.minificationFilter = .linear
                    itemLayer.isPictureAndTitleLayoutSuspended = false
                }
                CATransaction.commit()
                completion()
            }
        }
        springboardLayer.opacity = 0
        if isAnimated {
            for panelLayer in [tintLayer, maskLayer] {
                panelLayer.frame = folderMetrics.panelFrame
                panelLayer.cornerRadius = SpringboardFolderMetrics.panelCornerRadius
            }
            titleLayer.frame = titleFrame
            titleLayer.opacity = 1
            springboardLayer.transform = CATransform3DMakeScale(0.95, 0.95, 1)
            pages.scrollLayer.position = scrollPosition
            for itemLayer in firstPageItemLayers {
                itemLayer.opacity = 1
                itemLayer.imageLayer.frame = itemLayer.iconFrame
                itemLayer.labelLayer.frame = itemLayer.restingLabelFrame
                itemLayer.labelLayer.opacity = 1
            }
        }
        CATransaction.commit()
    }

    /// The reverse of opening, as 15's `animatedHide` (15.5 `GroupLayer_animatedHideBlock` `0x10004E63C`)
    /// did: the pages slide with the container shrinking onto the folder's cell, the first page's pictures
    /// fly into the thumbnails with their titles fading under them, and the title and the page dots fade
    /// back over and under the icon. 15 did this to the first page even when another one showed; that one
    /// only slides away under the shrinking panel. `completion` runs once the panel is gone and the folder
    /// icon is back.
    func animateClose(to folderItemLayer: SpringboardItemLayer?, springboardLayer: CALayer, completion: @escaping @MainActor () -> Void) {
        let isAnimated = !SpringboardPreferences.reducesMotion
        let firstPageItemLayers = Self.itemLayersInPanel(pages.pageGrids.first?.itemLayers ?? [], folderLayer: folderLayer)

        if !isAnimated {
            // The panel goes at once; only the pages fade back.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            folderLayer.opacity = 0
            CATransaction.commit()
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.animationDuration)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.folderLayer.removeFromSuperlayer()
                folderItemLayer?.opacity = 1
                CATransaction.commit()
                self.pages.tearDown()
                completion()
            }
        }
        if isAnimated, let folderItemLayer {
            let backdropRect = rectInFolder(folderItemLayer.folderBackdropFrame, of: folderItemLayer, springboardLayer: springboardLayer)
            let folderCellRect = rectInFolder(folderItemLayer.bounds, of: folderItemLayer, springboardLayer: springboardLayer)
            let thumbnailGridRect = rectInFolder(folderItemLayer.thumbnailGridFrame, of: folderItemLayer, springboardLayer: springboardLayer)
            for panelLayer in [tintLayer, maskLayer] {
                panelLayer.frame = backdropRect
                panelLayer.cornerRadius = folderItemLayer.folderCornerRadius
            }
            let scrollPosition = pages.scrollLayer.position
            pages.scrollLayer.position = CGPoint(x: scrollPosition.x + folderCellRect.minX, y: scrollPosition.y + folderCellRect.minY)
            let pagerControlSize = pages.pagerControlLayer.bounds.size
            pages.pagerControlLayer.frame = CGRect(
                x: folderCellRect.midX - pagerControlSize.width / 2,
                y: folderCellRect.minY,
                width: pagerControlSize.width,
                height: pagerControlSize.height
            )
            titleLayer.frame = Self.titleFrameOverFolder(cellRect: folderCellRect, titleSize: titleLayer.bounds.size)
            // After the pages have moved, so that the pictures land on the thumbnails wherever the pages end up.
            minimize(firstPageItemLayers, intoThumbnailGrid: thumbnailGridRect)
        } else {
            folderLayer.opacity = 0
        }
        titleLayer.opacity = 0
        pages.pagerControlLayer.opacity = 0
        springboardLayer.opacity = 1
        springboardLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// The icons of a page that are still in the panel. The grid keeps listing an icon a drag took out of
    /// the folder; closing must not fly that one into the thumbnails or fade it, or it vanishes in hand.
    static func itemLayersInPanel<ItemLayer: CALayer>(_ itemLayers: [ItemLayer], folderLayer: CALayer) -> [ItemLayer] {
        itemLayers.filter { itemLayer in
            var ancestorLayer = itemLayer.superlayer
            while let currentLayer = ancestorLayer {
                if currentLayer === folderLayer {
                    return true
                }
                ancestorLayer = currentLayer.superlayer
            }
            return false
        }
    }

    /// `rect`, in `itemLayer`, as it will be in the folder layer once the springboard is back at full
    /// size — the springboard's 0.95 scale is only ever an animation away.
    private func rectInFolder(_ rect: CGRect, of itemLayer: CALayer, springboardLayer: CALayer) -> CGRect {
        let rectInSpringboard = itemLayer.convert(rect, to: springboardLayer)
        let springboardOrigin = CGPoint(
            x: springboardLayer.position.x - springboardLayer.bounds.width * springboardLayer.anchorPoint.x,
            y: springboardLayer.position.y - springboardLayer.bounds.height * springboardLayer.anchorPoint.y
        )
        return rectInSpringboard.offsetBy(dx: springboardOrigin.x - folderLayer.frame.minX, dy: springboardOrigin.y - folderLayer.frame.minY)
    }

    /// 15's `_minimizeItemLayers` (15.5 `0x10004D93C`): each picture of the first page over its thumbnail
    /// in the folder icon's grid, `thumbnailGridRect` in the folder layer, and each title just under its
    /// picture, faded; the icons after the ninth fade as a whole. Only the pictures and titles move, inside
    /// cells that stay put, and shrunk pictures are filtered with Lanczos. Layout leaves them there until
    /// the panel is open again.
    private func minimize(_ itemLayers: [SpringboardItemLayer], intoThumbnailGrid thumbnailGridRect: CGRect) {
        let iconFrames = Self.minimizedIconFrames(count: itemLayers.count, thumbnailGridFrame: thumbnailGridRect, columnCount: folderMetrics.columnCount)
        let lanczosFilter = QuartzCorePrivate.stringConstant(named: "kCAFilterLanczos").map(CALayerContentsFilter.init(rawValue:)) ?? .trilinear
        for (itemIndex, itemLayer) in itemLayers.enumerated() {
            itemLayer.isPictureAndTitleLayoutSuspended = true
            let iconFrame = iconFrames[itemIndex]
            let labelFrame = Self.minimizedLabelFrame(under: iconFrame, labelSize: itemLayer.restingLabelFrame.size)
            itemLayer.imageLayer.frame = folderLayer.convert(iconFrame, to: itemLayer)
            itemLayer.labelLayer.frame = folderLayer.convert(labelFrame, to: itemLayer)
            itemLayer.labelLayer.opacity = 0
            if itemIndex < Self.thumbnailCount {
                itemLayer.imageLayer.minificationFilter = lanczosFilter
            } else {
                itemLayer.opacity = 0
                itemLayer.imageLayer.minificationFilter = .linear
            }
        }
    }

    /// Where 15 put the pictures of a folder's first page while the panel was shut
    /// (`-[ECSBGroupLayer _minimizeItemLayers]`, 15.5 `0x10004D93C`), in the coordinates of
    /// `thumbnailGridFrame`, y up. The first nine lie on the folder icon's 3 × 3 thumbnails: cells a third
    /// of the grid wide and high, truncated, inset by 2 points. The rest carry on the way 15's loop did —
    /// the tenth under the grid's first column, then from the fourth column of the second row on,
    /// `columnCount` to a row — and are never seen there, since they fade.
    static func minimizedIconFrames(count: Int, thumbnailGridFrame: CGRect, columnCount: Int) -> [CGRect] {
        let cellWidth = floor(thumbnailGridFrame.width / 3)
        let cellHeight = floor(thumbnailGridFrame.height / 3)
        var iconFrames: [CGRect] = []
        iconFrames.reserveCapacity(count)
        // 15 counted the cells of a row apart from the column it placed at, which drift apart after the ninth.
        var cellCountInRow = 0
        var column = 0
        var row = 0
        var isPastThumbnails = false
        for itemIndex in 0..<count {
            iconFrames.append(CGRect(
                x: thumbnailGridFrame.minX + 2 + CGFloat(column) * cellWidth,
                y: thumbnailGridFrame.maxY + 2 - CGFloat(row + 1) * cellHeight,
                width: cellWidth - 4,
                height: cellHeight - 4
            ))
            let rowLength: Int
            if itemIndex < thumbnailCount {
                rowLength = 3
            } else if !isPastThumbnails {
                isPastThumbnails = true
                cellCountInRow = 2
                column = 3
                row = 1
                continue
            } else {
                rowLength = columnCount
            }
            cellCountInRow += 1
            if cellCountInRow == rowLength {
                cellCountInRow = 0
                column = 0
                row += 1
            } else {
                column += 1
            }
        }
        return iconFrames
    }

    /// A title's place under its minimized picture: centred on it, truncated to a whole point, its top on
    /// the picture's bottom (`_minimizeItemLayers`).
    static func minimizedLabelFrame(under iconFrame: CGRect, labelSize: CGSize) -> CGRect {
        CGRect(
            x: (iconFrame.minX + iconFrame.width / 2 - labelSize.width / 2).rounded(.towardZero),
            y: iconFrame.minY - labelSize.height,
            width: labelSize.width,
            height: labelSize.height
        )
    }

    /// Where 15 put the title while the panel was shut: centred over the folder's cell, its bottom on the
    /// top of the cell (`_minimizePagerElements`, 15.5 `0x10004D6BC`).
    static func titleFrameOverFolder(cellRect: CGRect, titleSize: CGSize) -> CGRect {
        CGRect(x: cellRect.midX - titleSize.width / 2, y: cellRect.maxY, width: titleSize.width, height: titleSize.height)
    }
}

/// Renaming a folder: the title's text, editable, with a blinking caret after it.
///
/// 15 hosted a real text field from another process here, as in the search field; this edits the
/// Dock's key events directly, so there is no input method either.
final class SpringboardTitleEditorLayer: CALayer {
    private let textLayer = DockLayerFactory.makeTextLayer(withShadow: true)
    private let caretLayer = CALayer()
    private(set) var text = ""

    override init() {
        super.init()
        textLayer.font = SpringboardTypography.folderTitleFont
        textLayer.fontSize = CTFontGetSize(SpringboardTypography.folderTitleFont)
        textLayer.foregroundColor = CGColor(gray: 1, alpha: 1)
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .start
        DockLayerFactory.setTextShadow(of: textLayer, color: CGColor(gray: 0, alpha: 0.2), offset: CGSize(width: 0, height: -1), blur: 2)
        caretLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
        addSublayer(textLayer)
        addSublayer(caretLayer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(scale: CGFloat) {
        contentsScale = scale
        textLayer.contentsScale = scale
    }

    func setText(_ newText: String) {
        text = newText
        textLayer.string = newText
        setNeedsLayout()
    }

    func startBlinking() {
        let blinkAnimation = CABasicAnimation(keyPath: "opacity")
        blinkAnimation.fromValue = 1
        blinkAnimation.toValue = 0
        blinkAnimation.duration = 0.5
        blinkAnimation.autoreverses = true
        blinkAnimation.repeatCount = .infinity
        caretLayer.add(blinkAnimation, forKey: "blink")
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = SpringboardLabelLayer.textInset
        textLayer.frame = bounds.insetBy(dx: inset + 4, dy: inset)
        let textWidth = min(SpringboardTypography.width(of: text, in: SpringboardTypography.folderTitleFont), textLayer.frame.width)
        let lineHeight = SpringboardTypography.lineHeight(of: SpringboardTypography.folderTitleFont)
        caretLayer.frame = CGRect(x: bounds.midX + textWidth / 2 + 1, y: bounds.midY - lineHeight / 2 + 2, width: 2, height: lineHeight - 4)
        CATransaction.commit()
    }
}
