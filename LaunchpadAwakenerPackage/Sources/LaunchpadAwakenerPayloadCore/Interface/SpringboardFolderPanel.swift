import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// An open folder; macOS 15's `ECSBGroupLayer`.
///
/// A frosted rounded panel — `CABackdropLayer`, white 97 % at half opacity, blur 30 and saturation 1.8,
/// corner radius 36 — holding the folder's pages on the Dock's `ECGridLayer`, its own page dots, and
/// the title above it in Light 28 (`-[ECSBGroupLayer initWithGroup:groupPager:layoutRTL:]`,
/// 15.5 `0x10004BE70`). Opening grows the panel out of the folder icon's square while the icons fly from
/// the thumbnails to their cells; closing reverses it (`animatedShow` `0x10004E0E4`, `animatedHide`
/// `0x10004E63C`, both default 0.25 s animations).
///
/// 15's backdrop frosted the wallpaper picture drawn in the same window. The background is now glass
/// that the window server fills, so the backdrop is the window server's too, and sits outside the mask:
/// a mask draws what it clips off screen, where a window-server backdrop has nothing behind it.
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
    private let backdropLayer = QuartzCorePrivate.makeBackdropLayer(isWindowServerAware: true)
    let titleLayer = SpringboardLabelLayer(font: SpringboardTypography.folderTitleFont)
    let titleEditorLayer = SpringboardTitleEditorLayer()
    private let scale: CGFloat

    init(folder: LaunchpadFolder, metrics: SpringboardMetrics, scale: CGFloat, itemLayerWasFilled: @escaping (SpringboardItemLayer) -> Void) {
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
        backdropLayer.backgroundColor = SpringboardItemLayer.folderBackdropColor
        backdropLayer.cornerCurve = .continuous
        backdropLayer.masksToBounds = true
        // The Dock's own glass puts its blur in a backdrop's `filters`, as this does.
        backdropLayer.filters = QuartzCorePrivate.folderBackdropFilters()
        for panelLayer in [backdropLayer, maskLayer] {
            panelLayer.frame = folderMetrics.panelFrame
            panelLayer.cornerRadius = SpringboardFolderMetrics.panelCornerRadius
        }
        pages.scrollLayer.frame = folderMetrics.scrollFrame
        pages.pagerControlLayer.frame = folderMetrics.pagerControlFrame
        maskContainerLayer.addSublayer(pages.scrollLayer)
        maskContainerLayer.addSublayer(pages.pagerControlLayer)
        folderLayer.addSublayer(backdropLayer)
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

    /// Grows the panel out of `folderItemLayer`'s square and flies the first nine icons out of its
    /// thumbnails. `containerLayer` is the folder layer's superlayer; `springboardLayer` fades to 0
    /// and shrinks to 0.95 meanwhile, as 15's main grid did. With Reduce Motion the panel appears at
    /// once and the pages only fade, as in 15.
    func animateOpen(from folderItemLayer: SpringboardItemLayer, springboardLayer: CALayer, containerLayer: CALayer, completion: @escaping @MainActor () -> Void) {
        let isAnimated = !SpringboardPreferences.reducesMotion
        let backdropRect = rectInFolder(folderItemLayer.folderBackdropFrame, of: folderItemLayer, springboardLayer: springboardLayer)
        let folderCellRect = rectInFolder(folderItemLayer.bounds, of: folderItemLayer, springboardLayer: springboardLayer)
        let thumbnailRects = folderItemLayer.thumbnailLayers.prefix(9).map { thumbnailLayer in
            rectInFolder(thumbnailLayer.convert(thumbnailLayer.bounds, to: folderItemLayer), of: folderItemLayer, springboardLayer: springboardLayer)
        }
        let firstPageItemLayers = pages.pageGrids.first?.itemLayers ?? []
        let titleFrame = titleLayer.frame

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.addSublayer(folderLayer)
        if isAnimated {
            for panelLayer in [backdropLayer, maskLayer] {
                panelLayer.frame = backdropRect
                panelLayer.cornerRadius = folderItemLayer.folderCornerRadius
            }
            // 15 starts the title over the folder icon, its bottom on the top of the icon's cell.
            titleLayer.frame = CGRect(
                x: folderCellRect.midX - titleFrame.width / 2,
                y: folderCellRect.maxY,
                width: titleFrame.width,
                height: titleFrame.height
            )
            titleLayer.opacity = 0
        }
        pages.pagerControlLayer.opacity = 0
        folderItemLayer.opacity = 0
        // The grid has placed its items; lay them out now so their icon frames are known.
        firstPageItemLayers.forEach { $0.layoutIfNeeded() }
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
                completion()
            }
        }
        springboardLayer.opacity = 0
        if isAnimated {
            for panelLayer in [backdropLayer, maskLayer] {
                panelLayer.frame = folderMetrics.panelFrame
                panelLayer.cornerRadius = SpringboardFolderMetrics.panelCornerRadius
            }
            titleLayer.frame = titleFrame
            titleLayer.opacity = 1
            springboardLayer.transform = CATransform3DMakeScale(0.95, 0.95, 1)
            for (itemIndex, itemLayer) in firstPageItemLayers.enumerated() {
                if thumbnailRects.indices.contains(itemIndex) {
                    flyIconLayer(itemLayer, betweenThumbnailRect: thumbnailRects[itemIndex], isOpening: true)
                } else {
                    addOpacityAnimation(to: itemLayer, from: 0, to: 1)
                }
            }
        }
        CATransaction.commit()
    }

    /// The reverse of opening; `completion` runs once the panel is gone and the folder icon is back.
    func animateClose(to folderItemLayer: SpringboardItemLayer?, springboardLayer: CALayer, completion: @escaping @MainActor () -> Void) {
        let backdropRect = folderItemLayer.map { rectInFolder($0.folderBackdropFrame, of: $0, springboardLayer: springboardLayer) }
        let thumbnailRects = folderItemLayer.map { folderItemLayer in
            folderItemLayer.thumbnailLayers.prefix(9).map { thumbnailLayer in
                rectInFolder(thumbnailLayer.convert(thumbnailLayer.bounds, to: folderItemLayer), of: folderItemLayer, springboardLayer: springboardLayer)
            }
        } ?? []
        let visibleItemLayers = pages.currentPageGrid?.itemLayers ?? []

        if SpringboardPreferences.reducesMotion {
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
        if let backdropRect, let folderItemLayer {
            for panelLayer in [backdropLayer, maskLayer] {
                panelLayer.frame = backdropRect
                panelLayer.cornerRadius = folderItemLayer.folderCornerRadius
            }
        } else {
            folderLayer.opacity = 0
        }
        titleLayer.opacity = 0
        pages.pagerControlLayer.opacity = 0
        springboardLayer.opacity = 1
        springboardLayer.transform = CATransform3DIdentity
        for (itemIndex, itemLayer) in visibleItemLayers.enumerated() {
            if pages.currentPageIndex == 0, thumbnailRects.indices.contains(itemIndex) {
                flyIconLayer(itemLayer, betweenThumbnailRect: thumbnailRects[itemIndex], isOpening: false)
            } else {
                addOpacityAnimation(to: itemLayer, from: 1, to: 0)
            }
        }
        CATransaction.commit()
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

    /// Animates an item between showing its icon over `thumbnailRect` (in the folder layer) and its cell.
    private func flyIconLayer(_ itemLayer: SpringboardItemLayer, betweenThumbnailRect thumbnailRect: CGRect, isOpening: Bool) {
        guard let superlayer = itemLayer.superlayer, itemLayer.iconFrame.width > 0 else { return }
        let thumbnailInSuperlayer = folderLayer.convert(thumbnailRect, to: superlayer)
        let thumbnailScale = thumbnailInSuperlayer.width / itemLayer.iconFrame.width
        // Scaling happens around the anchor, the cell's centre; place the cell so the icon's centre
        // lands on the thumbnail's centre.
        let iconOffset = CGPoint(x: itemLayer.iconFrame.midX - itemLayer.bounds.midX, y: itemLayer.iconFrame.midY - itemLayer.bounds.midY)
        let thumbnailPosition = CGPoint(
            x: thumbnailInSuperlayer.midX - thumbnailScale * iconOffset.x,
            y: thumbnailInSuperlayer.midY - thumbnailScale * iconOffset.y
        )
        let positionAnimation = CABasicAnimation(keyPath: "position")
        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        let labelOpacityAnimation = CABasicAnimation(keyPath: "opacity")
        if isOpening {
            positionAnimation.fromValue = thumbnailPosition
            scaleAnimation.fromValue = thumbnailScale
            labelOpacityAnimation.fromValue = 0
        } else {
            positionAnimation.toValue = thumbnailPosition
            scaleAnimation.toValue = thumbnailScale
            labelOpacityAnimation.toValue = 0
            for animation in [positionAnimation, scaleAnimation, labelOpacityAnimation] {
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
            }
        }
        itemLayer.add(positionAnimation, forKey: "folderPosition")
        itemLayer.add(scaleAnimation, forKey: "folderScale")
        itemLayer.labelLayer.add(labelOpacityAnimation, forKey: "folderLabelOpacity")
    }

    private func addOpacityAnimation(to layer: CALayer, from fromOpacity: Float, to toOpacity: Float) {
        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = fromOpacity
        opacityAnimation.toValue = toOpacity
        if toOpacity < fromOpacity {
            opacityAnimation.fillMode = .forwards
            opacityAnimation.isRemovedOnCompletion = false
        }
        layer.add(opacityAnimation, forKey: "folderOpacity")
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
