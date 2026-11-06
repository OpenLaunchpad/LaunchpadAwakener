import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// An open folder; macOS 15's `ECSBGroupLayer`.
///
/// A frosted rounded panel — `CABackdropLayer`, white 97 % at half opacity, blur 30 and saturation 1.8,
/// corner radius 36 — holding the folder's pages on the Dock's `ECGridLayer`, its own page dots, and
/// the title above it in Light 28 (`-[ECSBGroupLayer initWithGroup:groupPager:layoutRTL:]`,
/// 15.5 `0x10004BE70`). Opening grows the panel out of the folder icon's square over the icons, which
/// stay in their cells and fade in; closing shrinks it back while the icons fly into the thumbnails
/// (`animatedShow` `0x10004E0E4`, `animatedHide` `0x10004E63C`, both default 0.25 s animations). 15 flew
/// the icons out of the thumbnails when opening too — `_minimizeItemLayers` `0x10004D93C` put each
/// picture on its thumbnail and the animated `-[ECSBGridLayer _layoutItemLayers]` `0x10001F338` laid it
/// back in its cell — but here they stay put, a deliberate departure recorded in the proposal.
///
/// 15's frosting was a live backdrop over its blurred wallpaper. Here the wallpaper behind the panel is a
/// fixed picture, so the frosting is that picture once more through the panel's filters, under the
/// white tint (``Frost/wallpaper(_:screenSize:)``): on macOS 27 a live backdrop redrew wrongly wherever
/// part of the screen changed — the cell of a pressed icon went dark. Over the glass background, which
/// the window server composites, the backdrop is the window server's, outside the mask: a mask draws
/// what it clips off screen, where a window-server backdrop has nothing behind it.
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
    /// The panel's shape as it grows and shrinks: the tinted frosting, or the tint over a fixed frosting.
    private let backdropLayer: CALayer
    let titleLayer = SpringboardLabelLayer(font: SpringboardTypography.folderTitleFont)
    let titleEditorLayer = SpringboardTitleEditorLayer()
    private let scale: CGFloat

    /// Where the panel's frosting comes from.
    enum Frost {
        /// The wallpaper picture behind the springboard, filtered again: fixed, worked out once.
        case wallpaper(CGImage, screenSize: CGSize)
        /// A backdrop the window server fills, for the glass background.
        case windowServerBackdrop
        /// A backdrop filled from the window's own layers, over 15's gradient.
        case windowBackdrop
    }

    init(
        folder: LaunchpadFolder,
        metrics: SpringboardMetrics,
        scale: CGFloat,
        frost: Frost,
        itemLayerWasFilled: @escaping (SpringboardItemLayer) -> Void
    ) {
        self.folder = folder
        self.scale = scale
        backdropLayer = switch frost {
        case .wallpaper: CALayer()
        case .windowServerBackdrop: QuartzCorePrivate.makeBackdropLayer(isWindowServerAware: true)
        case .windowBackdrop: QuartzCorePrivate.makeBackdropLayer(isWindowServerAware: false)
        }
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
        for panelLayer in [backdropLayer, maskLayer] {
            panelLayer.frame = folderMetrics.panelFrame
            panelLayer.cornerRadius = SpringboardFolderMetrics.panelCornerRadius
        }
        pages.scrollLayer.frame = folderMetrics.scrollFrame
        pages.pagerControlLayer.frame = folderMetrics.pagerControlFrame
        switch frost {
        case let .wallpaper(wallpaperImage, screenSize):
            // The wallpaper where the springboard's background shows it, through the background's filters
            // and then the panel's; the mask cuts out the panel.
            let frostLayer = CALayer()
            frostLayer.frame = CGRect(origin: CGPoint(x: -folderMetrics.folderFrame.minX, y: -folderMetrics.folderFrame.minY), size: screenSize)
            frostLayer.contents = wallpaperImage
            frostLayer.filters = (QuartzCorePrivate.desktopBackgroundFilters() ?? []) + (QuartzCorePrivate.folderBackdropFilters() ?? [])
            frostLayer.shouldRasterize = true
            frostLayer.rasterizationScale = scale
            maskContainerLayer.addSublayer(frostLayer)
            maskContainerLayer.addSublayer(backdropLayer)
        case .windowServerBackdrop:
            // The Dock's own glass puts its blur in a backdrop's `filters`, as this does.
            backdropLayer.filters = QuartzCorePrivate.folderBackdropFilters()
            folderLayer.addSublayer(backdropLayer)
        case .windowBackdrop:
            backdropLayer.filters = QuartzCorePrivate.folderBackdropFilters()
            maskContainerLayer.addSublayer(backdropLayer)
        }
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

    /// Grows the panel out of `folderItemLayer`'s square over the first page's icons, which stay in their
    /// cells and fade in. `containerLayer` is the folder layer's superlayer; `springboardLayer` fades to
    /// 0 and shrinks to 0.95 meanwhile, as 15's main grid did. With Reduce Motion the panel appears at
    /// once and the pages only fade, as in 15.
    func animateOpen(from folderItemLayer: SpringboardItemLayer, springboardLayer: CALayer, containerLayer: CALayer, completion: @escaping @MainActor () -> Void) {
        let isAnimated = !SpringboardPreferences.reducesMotion
        let backdropRect = rectInFolder(folderItemLayer.folderBackdropFrame, of: folderItemLayer, springboardLayer: springboardLayer)
        let folderCellRect = rectInFolder(folderItemLayer.bounds, of: folderItemLayer, springboardLayer: springboardLayer)
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
            // Unfaded, whichever icon lies under the folder's square would show a piece of itself there
            // in the first frame instead of the folder's frosting.
            firstPageItemLayers.forEach { $0.opacity = 0 }
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
            firstPageItemLayers.forEach { $0.opacity = 1 }
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
        let visibleItemLayers = Self.itemLayersInPanel(pages.currentPageGrid?.itemLayers ?? [], folderLayer: folderLayer)

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
                flyIconLayer(itemLayer, intoThumbnailRect: thumbnailRects[itemIndex])
            } else {
                addOpacityAnimation(to: itemLayer, from: 1, to: 0)
            }
        }
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

    /// Flies an item from its cell until its icon lies over `thumbnailRect` (in the folder layer), fading
    /// its title; it stays there until the panel is gone.
    private func flyIconLayer(_ itemLayer: SpringboardItemLayer, intoThumbnailRect thumbnailRect: CGRect) {
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
        positionAnimation.toValue = thumbnailPosition
        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.toValue = thumbnailScale
        let labelOpacityAnimation = CABasicAnimation(keyPath: "opacity")
        labelOpacityAnimation.toValue = 0
        for animation in [positionAnimation, scaleAnimation, labelOpacityAnimation] {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
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
