import CoreGraphics
import CoreText
import Foundation
import ImageIO
import QuartzCore

/// A title; macOS 15's `ECSBLabelLayer`, which drew with the Dock's `ECShadowTextLayer`.
///
/// White, middle truncation, a black 20 % shadow 1 point down with a 2-point blur
/// (15.5 `-[ECSBLabelLayer initWithString:andScaleFactor:]`, `0x10001FD60`). The text sits 2 points
/// inside the label on every side. Icons use Medium 13, an open folder's title Light 28. A new string
/// shows at once, so a renamed folder's title does not fade from the old name to the new one.
final class SpringboardLabelLayer: CALayer {
    static let textInset: CGFloat = 2

    let textLayer: CATextLayer = SpringboardHostSystem.layerFactory.makeTextLayer(withShadow: true)
    private var font: CTFont = SpringboardTypography.labelFont

    convenience init(font: CTFont) {
        self.init()
        self.font = font
        textLayer.font = font
        textLayer.fontSize = CTFontGetSize(font)
    }

    override init() {
        super.init()
        textLayer.font = font
        textLayer.fontSize = CTFontGetSize(font)
        textLayer.foregroundColor = CGColor(gray: 1, alpha: 1)
        textLayer.truncationMode = .middle
        textLayer.alignmentMode = .center
        SpringboardHostSystem.layerFactory.setTextShadow(of: textLayer, color: CGColor(gray: 0, alpha: 0.2), offset: CGSize(width: 0, height: -1), blur: 2)
        textLayer.disableTextCrossfade()
        addSublayer(textLayer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    var string: String {
        (textLayer.string as? String) ?? ""
    }

    /// Left-aligned to make room for a blue dot that does not fit beside the centred text.
    var isLeftAligned = false {
        didSet {
            guard isLeftAligned != oldValue else { return }
            textLayer.alignmentMode = isLeftAligned ? .left : .center
        }
    }

    /// The blue dot of an application downloaded from the App Store and not launched since; it hangs off
    /// the label's left side, so it moves and fades with the title.
    private var recentlyAddedDotLayer: CALayer?

    /// 15's dot colour (`-[ECFlagLayer initWithStyle:]`, 15.5 `0x1000E7FC8`).
    static let recentlyAddedDotColor = CGColor(red: 0, green: 122 / 255, blue: 1, alpha: 1)
    static let recentlyAddedDotSide: CGFloat = 9

    /// Shows or removes the dot. `flagSide` is the side of 15's `ECFlagLayer`, the label's height less 8;
    /// the dot sits centred in it, the flag's left edge `flagSide − 1` before the label and 5 points up
    /// (`-[ECFlagLayer layout]`, `0x1000E812C`; `-[ECSBItemLayer layout]`, `0x100020A14`).
    func setRecentlyAddedDot(isShown: Bool, flagSide: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard isShown else {
            recentlyAddedDotLayer?.removeFromSuperlayer()
            recentlyAddedDotLayer = nil
            return
        }
        let dotLayer = recentlyAddedDotLayer ?? CALayer()
        if recentlyAddedDotLayer == nil {
            dotLayer.backgroundColor = Self.recentlyAddedDotColor
            dotLayer.cornerRadius = Self.recentlyAddedDotSide / 2
            addSublayer(dotLayer)
            recentlyAddedDotLayer = dotLayer
        }
        let dotInset = CGFloat(Int(flagSide / 2 - Self.recentlyAddedDotSide / 2))
        dotLayer.frame = CGRect(x: 1 - flagSide + dotInset, y: 5 + dotInset, width: Self.recentlyAddedDotSide, height: Self.recentlyAddedDotSide)
    }

    var showsRecentlyAddedDot: Bool {
        recentlyAddedDotLayer != nil
    }

    func setString(_ string: String, contentsScale scale: CGFloat) {
        textLayer.string = string
        textLayer.contentsScale = scale
        contentsScale = scale
    }

    /// `(text width + 4, line height + 7)`: the inset on both sides, plus room for the blur and the
    /// downward offset of the shadow (`-[ECSBLabelLayer preferredFrameSize]`, `0x1000210F0`).
    static func preferredSize(of string: String, font: CTFont = SpringboardTypography.labelFont) -> CGSize {
        CGSize(
            width: SpringboardTypography.width(of: string, in: font) + 2 * textInset,
            height: SpringboardTypography.lineHeight(of: font) + 7
        )
    }

    var preferredSize: CGSize {
        Self.preferredSize(of: string, font: font)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.frame = bounds.insetBy(dx: Self.textInset, dy: Self.textInset)
        CATransaction.commit()
    }
}

/// Feeds a folder icon's thumbnails to the Dock's `ECImageGridLayer`, as 15's `ECSBGroup` did.
package final class SpringboardThumbnailSource: NSObject {
    var images: [CGImage?] = []
    var scale: CGFloat = 2

    @objc(numberOfItemsForLayer:)
    func numberOfItems(forLayer gridLayer: CALayer) -> UInt {
        UInt(images.count)
    }

    @objc(makeLayerForLayer:)
    func makeLayer(forLayer gridLayer: CALayer) -> CALayer {
        let thumbnailLayer = CALayer()
        thumbnailLayer.contentsGravity = .resizeAspect
        thumbnailLayer.contentsScale = scale
        return thumbnailLayer
    }

    @objc(setContentInLayers:withDataRange:forLayer:usingScaleFactor:)
    func setContent(inLayers layers: NSArray, withDataRange dataRange: NSRange, forLayer gridLayer: CALayer, usingScaleFactor scaleFactor: Float) {
        for (offset, layer) in layers.enumerated() {
            let imageIndex = dataRange.location + offset
            guard let thumbnailLayer = layer as? CALayer, images.indices.contains(imageIndex) else { continue }
            thumbnailLayer.contents = images[imageIndex]
        }
    }
}

/// One cell of a page: an application or a folder with its title; macOS 15's `ECSBItemLayer` and
/// `ECSBGroupItemLayer`.
///
/// Positioned by the Dock's `ECGridLayer`, which sets each item's bounds to a whole cell; this lays the
/// icon and title out inside the cell (`-[ECSBItemLayer layout]`, 15.5 `0x100020A14`). A folder has no
/// icon image: a frosted square (white 97 % at half opacity, no blur) with a 3 × 3 grid of its first
/// page's icons on the Dock's `ECImageGridLayer`.
final class SpringboardItemLayer: CALayer {
    static let folderBackdropColor = CGColor(gray: 0.9686, alpha: 0.5)
    /// The darker square behind a target while something is dragged over it.
    static let dropTargetTintColor = CGColor(gray: 0.9412, alpha: 1)

    private(set) var item: LaunchpadItem?
    private var metrics: SpringboardMetrics?

    /// Everything the icon draws, in a layer of its own that shakes in jiggle mode, as 15's
    /// `jitterLayer` was; it fills the item, so it shares the item's coordinates.
    ///
    /// It does not blend as a group, as 15's did not (`-[ECSBItemLayer initWithScaleFactor:layoutRTL:]`,
    /// 15.5 `0x100060514`): the selection's plus-darker and a drop target's darkening tint then work on
    /// the wallpaper behind the item. A layer that blends as a group keeps its sublayers' compositing
    /// filters to itself, where those two had nothing beneath them and showed as opaque light grey.
    let jitterLayer = CALayer()
    /// The picture alone, blending as a group the way the Dock's tiles keep theirs in a content layer
    /// (`-[DOCKTileLayer init]`, 27.2 `0x10007E348`): the compositing filter of the clear and tinted icon
    /// styles works on the picture, not on the wallpaper. It fills the jitter layer, so the picture's
    /// frame is in the jitter layer's coordinates.
    private let imageGroupLayer = CALayer()
    let imageLayer = CALayer()
    let labelLayer = SpringboardLabelLayer()
    private var selectionLayer: CALayer?
    /// A folder's frosted square, or an application's while something is dragged onto it.
    private var backdropLayer: CALayer?
    private var dropTargetTintLayer: CALayer?
    private var thumbnailGridLayer: CALayer?
    private let thumbnailSource = SpringboardThumbnailSource()

    override init() {
        super.init()
        imageLayer.contentsGravity = .resizeAspect
        imageGroupLayer.addSublayer(imageLayer)
        jitterLayer.addSublayer(imageGroupLayer)
        jitterLayer.addSublayer(labelLayer)
        // Core Animation's private `allowsGroupBlending`.
        jitterLayer.setValue(false, forKey: "allowsGroupBlending")
        addSublayer(jitterLayer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The icon, in this layer: only a press on it counts as a press on the item, as in 15.
    private(set) var iconFrame: CGRect = .zero
    /// Where the title rests, in this layer.
    private(set) var restingLabelFrame: CGRect = .zero
    /// While set, layout works out ``iconFrame`` and ``restingLabelFrame`` but leaves the picture and the
    /// title where an animation put them, as 15's `disableLayout` left them (`-[ECSBItemLayer layout]`,
    /// 15.5 `0x100020A14`, returned at once).
    var isPictureAndTitleLayoutSuspended = false

    /// The folder's frosted square, in this layer.
    var folderBackdropFrame: CGRect {
        guard let metrics else { return iconFrame }
        let inset = SpringboardFolderMetrics.folderBackdropInset(forIconSide: metrics.iconSide)
        return iconFrame.insetBy(dx: inset, dy: inset)
    }

    var folderCornerRadius: CGFloat {
        Self.cornerRadius(forIconSide: metrics?.iconSide ?? iconFrame.width)
    }

    /// A folder's 3 × 3 thumbnail grid, in this layer: the frosted square inset by a tenth of its width.
    /// An application has the same place, where its thumbnails would be once it turns into a folder.
    var thumbnailGridFrame: CGRect {
        let backdropFrame = folderBackdropFrame
        let gridInset = SpringboardFolderMetrics.thumbnailGridInset(forBackdropSide: backdropFrame.width)
        return backdropFrame.insetBy(dx: gridInset, dy: gridInset)
    }

    /// The thumbnail layers of a folder, in reading order: top row first, left to right.
    var thumbnailLayers: [CALayer] {
        guard let thumbnailGridLayer else { return [] }
        // ECImageGridLayer keeps its item layers in a scroll layer inside it, in no promised order.
        return (thumbnailGridLayer.sublayers ?? [])
            .flatMap { $0.sublayers ?? [] }
            .sorted { firstLayer, secondLayer in
                if firstLayer.frame.midY != secondLayer.frame.midY {
                    return firstLayer.frame.midY > secondLayer.frame.midY
                }
                return firstLayer.frame.midX < secondLayer.frame.midX
            }
    }

    var isFolder: Bool {
        if case .folder = item { true } else { false }
    }

    /// An application downloaded from the App Store and not launched since; folders never are.
    private var isRecentlyAdded: Bool {
        if case .application(let application) = item { application.isRecentlyAdded } else { false }
    }

    /// The title's width, its shift from the centred position and its alignment. With a flag
    /// `flagSide` wide hanging off its left, the title stays centred while both fit, and otherwise shrinks,
    /// moves right by half the flag and turns left-aligned (15.5 `-[ECSBItemLayer layout]`, `0x100020A14`).
    static func labelPlacement(preferredWidth: CGFloat, cellWidth: CGFloat, maximumWidth: CGFloat, flagSide: CGFloat?) -> (width: CGFloat, offset: CGFloat, isLeftAligned: Bool) {
        guard let flagSide else {
            return (min(preferredWidth, maximumWidth), 0, false)
        }
        guard preferredWidth + flagSide + 1 > maximumWidth else {
            return (preferredWidth, 0, false)
        }
        return (cellWidth - flagSide - 13, CGFloat(Int((flagSide + 1) / 2)), true)
    }

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateSelection()
        }
    }

    /// Pressed: the icon dims to 40 % (`-[ECSBItemLayer setDarkened:]`, `0x100060DA8`); a folder dims its
    /// square and thumbnails (`-[ECSBGroupItemLayer setDarkened:]`, `0x100076CEC`).
    var isDarkened = false {
        didSet {
            guard isDarkened != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let filters = isDarkened ? Self.darkeningFilters() : nil
            if isFolder {
                backdropLayer?.filters = filters
                thumbnailGridLayer?.filters = filters
            } else {
                imageLayer.filters = filters
            }
            CATransaction.commit()
        }
    }

    private static func darkeningFilters() -> [Any]? {
        guard
            let multiplyFilterType = QuartzCorePrivate.stringConstant(named: "kCAFilterMultiplyColor"),
            let darkeningFilter = QuartzCorePrivate.makeFilter(type: multiplyFilterType)
        else { return nil }
        darkeningFilter.setValue(CGColor(gray: 0.4, alpha: 1), forKey: "inputColor")
        return [darkeningFilter]
    }

    func configure(with item: LaunchpadItem, metrics: SpringboardMetrics, scale: CGFloat) {
        self.item = item
        self.metrics = metrics
        contentsScale = scale
        imageLayer.contentsScale = scale
        labelLayer.setString(item.title, contentsScale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch item {
        case .application:
            removeFolderLayers()
        case .folder:
            imageLayer.contents = nil
            makeFolderLayersIfNeeded(scale: scale)
        }
        CATransaction.commit()
        setNeedsLayout()
    }

    private func makeFolderLayersIfNeeded(scale: CGFloat) {
        if backdropLayer == nil {
            let newBackdropLayer = CALayer()
            newBackdropLayer.backgroundColor = Self.folderBackdropColor
            newBackdropLayer.cornerCurve = .continuous
            jitterLayer.insertSublayer(newBackdropLayer, below: imageGroupLayer)
            backdropLayer = newBackdropLayer
        }
        guard thumbnailGridLayer == nil else { return }
        thumbnailSource.scale = scale
        guard let newThumbnailGridLayer = SpringboardHostSystem.layerFactory.makeThumbnailGridLayer(
            source: thumbnailSource,
            rowCount: 3,
            columnCount: 3,
            spacing: 4,
            scaleFactor: Float(scale)
        ) else { return }
        newThumbnailGridLayer.masksToBounds = true
        newThumbnailGridLayer.allowsEdgeAntialiasing = false
        jitterLayer.addSublayer(newThumbnailGridLayer)
        thumbnailGridLayer = newThumbnailGridLayer
    }

    private func removeFolderLayers() {
        backdropLayer?.removeFromSuperlayer()
        backdropLayer = nil
        dropTargetTintLayer?.removeFromSuperlayer()
        dropTargetTintLayer = nil
        thumbnailGridLayer?.removeFromSuperlayer()
        thumbnailGridLayer = nil
    }

    /// An application's icon, with the compositing filter the Dock gives icons in the current style.
    func setApplicationIcon(_ icon: CGImage?, compositingFilterName: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = icon
        imageLayer.compositingFilter = compositingFilterName
        CATransaction.commit()
    }

    /// The icons of a folder's first page, in reading order; the grid shows the first nine.
    func setFolderThumbnails(_ thumbnails: [CGImage?]) {
        guard let thumbnailGridLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbnailSource.images = thumbnails
        SpringboardHostSystem.layerFactory.invalidateThumbnailGridLayer(thumbnailGridLayer, source: thumbnailSource)
        CATransaction.commit()
    }

    /// Where the thumbnail of the folder's `slot`th application is, or would be, in this layer — with the
    /// grid scrolled as it is now. `ECImageGridLayer` lays its thumbnails out row by row from the top
    /// left, a cell a third of the grid apart (15.5 `_layoutItemLayers`, `0x100023EE8`).
    func thumbnailFrame(atSlot slot: Int) -> CGRect? {
        guard let thumbnailGridLayer, slot >= 0 else { return nil }
        let thumbnailLayers = thumbnailLayers
        if thumbnailLayers.indices.contains(slot) {
            let thumbnailLayer = thumbnailLayers[slot]
            return thumbnailLayer.convert(thumbnailLayer.bounds, to: self)
        }
        let cellWidth = floor(thumbnailGridLayer.bounds.width / 3)
        let cellHeight = floor(thumbnailGridLayer.bounds.height / 3)
        let row = CGFloat(slot / 3)
        let column = CGFloat(slot % 3)
        guard let firstThumbnailLayer = thumbnailLayers.first, let itemsLayer = firstThumbnailLayer.superlayer else {
            // No thumbnails yet: the grid's own layout, unscrolled.
            let gridBounds = thumbnailGridLayer.bounds
            let frameInGrid = CGRect(
                x: 2 + column * cellWidth,
                y: gridBounds.height + 2 - (row + 1) * cellHeight,
                width: cellWidth - 4,
                height: cellHeight - 4
            )
            return thumbnailGridLayer.convert(frameInGrid, to: self)
        }
        let frameInItems = firstThumbnailLayer.frame.offsetBy(dx: column * cellWidth, dy: -row * cellHeight)
        return itemsLayer.convert(frameInItems, to: self)
    }

    /// Hides or shows the thumbnails of the given slots, without animation unless the transaction animates.
    func setThumbnailOpacity(_ opacity: Float, forSlots slots: Range<Int>) {
        let thumbnailLayers = thumbnailLayers
        for slot in slots where thumbnailLayers.indices.contains(slot) {
            thumbnailLayers[slot].opacity = opacity
        }
    }

    /// Scrolls a folder's thumbnails up to show the slot after its last application, as 15 did while an
    /// icon was held over the folder (`-[ECSBGroupItemLayer setDarkenedForDrop:]`, `0x100076F0C`), or back.
    func scrollThumbnails(toAvailableSpace: Bool) {
        guard let thumbnailGridLayer else { return }
        SpringboardHostSystem.layerFactory.scrollThumbnailGridLayer(thumbnailGridLayer, toAvailableSpace: toAvailableSpace)
    }

    /// The point size to render a folder's thumbnails at: the grid's row height less the spacing,
    /// clamped to 1…32 as `+[ECSBGroupItemLayer miniIconSizeForBounds:andScaleFactor:]` clamped it.
    static func thumbnailSide(forIconSide iconSide: CGFloat) -> CGFloat {
        let backdropSide = iconSide - 2 * SpringboardFolderMetrics.folderBackdropInset(forIconSide: iconSide)
        let gridSide = backdropSide - 2 * SpringboardFolderMetrics.thumbnailGridInset(forBackdropSide: backdropSide)
        return min(max(CGFloat(Int(gridSide) / 3) - 4, 1), 32)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        jitterLayer.frame = bounds
        imageGroupLayer.frame = jitterLayer.bounds
        CATransaction.commit()
        guard let metrics, let item else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let cellWidth = bounds.width
        let iconSide = metrics.iconSide
        let bottomPadding = min(ceil(bounds.height * 0.125), 20)
        iconFrame = CGRect(
            x: Self.centered(cellWidth / 2 - iconSide / 2, isEven: Int(iconSide).isMultiple(of: 2)),
            y: bottomPadding + metrics.labelHeight,
            width: iconSide,
            height: iconSide
        )
        let labelPlacement = Self.labelPlacement(
            preferredWidth: SpringboardLabelLayer.preferredSize(of: item.title).width,
            cellWidth: cellWidth,
            maximumWidth: metrics.labelMaximumWidth,
            flagSide: isRecentlyAdded ? metrics.labelHeight - 8 : nil
        )
        restingLabelFrame = CGRect(
            x: Self.centered(cellWidth / 2 - labelPlacement.width / 2, isEven: Int(labelPlacement.width).isMultiple(of: 2)) + labelPlacement.offset,
            y: bottomPadding,
            width: labelPlacement.width,
            height: metrics.labelHeight
        )
        labelLayer.isLeftAligned = labelPlacement.isLeftAligned
        labelLayer.setRecentlyAddedDot(isShown: isRecentlyAdded, flagSide: metrics.labelHeight - 8)
        if !isPictureAndTitleLayoutSuspended {
            imageLayer.frame = iconFrame
            labelLayer.frame = restingLabelFrame
        }
        if let closeBoxLayer {
            closeBoxLayer.frame = Self.closeBoxFrame(imageFrame: iconFrame, closeBoxSize: closeBoxLayer.bounds.size)
        }

        if isFolder {
            let backdropFrame = folderBackdropFrame
            backdropLayer?.frame = backdropFrame
            backdropLayer?.cornerRadius = folderCornerRadius
            if let thumbnailGridLayer {
                thumbnailGridLayer.frame = thumbnailGridFrame
                SpringboardHostSystem.layerFactory.layoutThumbnailGridLayer(thumbnailGridLayer)
            }
        } else if let backdropLayer {
            // An application showing the drop-target preview: a folder square 10 % larger than a folder's.
            backdropLayer.frame = folderBackdropFrame
            backdropLayer.cornerRadius = folderCornerRadius
            dropTargetTintLayer?.frame = folderBackdropFrame
            dropTargetTintLayer?.cornerRadius = folderCornerRadius
        }
        if let selectionLayer {
            selectionLayer.frame = selectionFrame
            selectionLayer.cornerRadius = Self.cornerRadius(forIconSide: iconSide)
        }
        CATransaction.commit()
    }

    /// 15 truncated even sizes and rounded odd ones when centring.
    private static func centered(_ origin: CGFloat, isEven: Bool) -> CGFloat {
        isEven ? origin.rounded(.towardZero) : origin.rounded()
    }

    /// `round(icon side × 0.15625)`, rounding half down as 15's `sub_10006AF28` did.
    static func cornerRadius(forIconSide iconSide: CGFloat) -> CGFloat {
        ceil(iconSide * 0.15625 - 0.5)
    }

    // MARK: - Jiggling

    /// Shakes in jiggle mode, as 15's icons did (`-[ECSBItemLayer setJittering:]`, `0x1000613FC`): the
    /// jitter layer turns and wanders by the additive animations of ``SpringboardJiggle``, so that the
    /// item's own geometry stays free for layout, dragging and the folder animations.
    var isJiggling = false {
        didSet {
            guard isJiggling != oldValue else { return }
            updateJiggle()
            updateCloseBox()
        }
    }

    // MARK: - Close box

    /// The Dock's uninstaller would delete the application, so jiggle mode shows a close box on it.
    var isDeletable = false {
        didSet {
            guard isDeletable != oldValue else { return }
            updateCloseBox()
        }
    }

    /// Confirmed for deletion: until the delete is over, the icon takes no presses and shows no close box.
    var isBeingDeleted = false {
        didSet {
            guard isBeingDeleted != oldValue else { return }
            updateCloseBox()
        }
    }

    /// Pressed, the close box shows its darker texture, as 15's did while the pointer stayed on it.
    var isCloseBoxPressed = false {
        didSet {
            guard isCloseBoxPressed != oldValue, let closeBoxLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            closeBoxLayer.contents = SpringboardTextures.image(named: isCloseBoxPressed ? "ecsb_closebox_pressed" : "ecsb_closebox", scale: contentsScale)
            CATransaction.commit()
        }
    }

    private var closeBoxLayer: CALayer?

    var showsCloseBox: Bool {
        closeBoxLayer != nil
    }

    /// Shown in jiggle mode on a deletable application, never on a folder, without animation
    /// (`-[ECSBItemLayer setCloseboxVisible:]`, 15.5 `0x1000616D4`); its texture's own size
    /// (`_makeCloseBoxLayer`, `0x100061E7C`), 28 points in Dock.app.
    private func updateCloseBox() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard isJiggling, isDeletable, !isFolder, !isBeingDeleted else {
            closeBoxLayer?.removeFromSuperlayer()
            closeBoxLayer = nil
            isCloseBoxPressed = false
            return
        }
        guard closeBoxLayer == nil, let closeBoxImage = SpringboardTextures.image(named: "ecsb_closebox", scale: contentsScale) else { return }
        let newCloseBoxLayer = CALayer()
        newCloseBoxLayer.contents = closeBoxImage
        newCloseBoxLayer.contentsScale = contentsScale
        newCloseBoxLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(closeBoxImage.width) / contentsScale, height: CGFloat(closeBoxImage.height) / contentsScale)
        newCloseBoxLayer.frame = Self.closeBoxFrame(imageFrame: iconFrame, closeBoxSize: newCloseBoxLayer.bounds.size)
        jitterLayer.addSublayer(newCloseBoxLayer)
        closeBoxLayer = newCloseBoxLayer
    }

    /// Centred 10 % of the image in from its top left corner (`-[ECSBItemLayer _closeboxFrame]`,
    /// 15.5 `0x1000621D0`), every part truncated as there.
    static func closeBoxFrame(imageFrame: CGRect, closeBoxSize: CGSize) -> CGRect {
        CGRect(
            x: imageFrame.minX + CGFloat(Int(imageFrame.width * 0.1)) - CGFloat(Int(closeBoxSize.width * 0.5)),
            y: imageFrame.maxY - (closeBoxSize.height + CGFloat(Int(imageFrame.height * 0.1))) + CGFloat(Int(closeBoxSize.height * 0.5)),
            width: closeBoxSize.width,
            height: closeBoxSize.height
        )
    }

    /// Whether `point`, a point in this layer, is on the close box.
    func isOnCloseBox(_ point: CGPoint) -> Bool {
        closeBoxLayer?.frame.contains(point) ?? false
    }

    /// Keeps the icon still whatever `isJiggling` says, as 15 did for an icon picked up, held down or with
    /// something held over it.
    var isHeldStill = false {
        didSet {
            guard isHeldStill != oldValue else { return }
            updateJiggle()
        }
    }

    private func updateJiggle() {
        let shouldShake = isJiggling && !isHeldStill
        guard shouldShake != (jitterLayer.animation(forKey: SpringboardJiggle.rotationAnimationKey) != nil) else { return }
        guard shouldShake else {
            jitterLayer.removeAnimation(forKey: SpringboardJiggle.positionAnimationKey)
            jitterLayer.removeAnimation(forKey: SpringboardJiggle.rotationAnimationKey)
            return
        }
        var generator = SystemRandomNumberGenerator()
        let animations = SpringboardJiggle.makeAnimations(using: &generator)
        jitterLayer.add(animations.position, forKey: SpringboardJiggle.positionAnimationKey)
        jitterLayer.add(animations.rotation, forKey: SpringboardJiggle.rotationAnimationKey)
    }

    // MARK: - Dragging

    /// Picked up: 1.1 times larger, title at 90 % (`-[ECSBItemLayer setMagnified:]`, `0x100061244`).
    var isMagnified = false {
        didSet {
            guard isMagnified != oldValue else { return }
            transform = isMagnified ? CATransform3DMakeScale(1.1, 1.1, 1) : CATransform3DIdentity
            labelLayer.opacity = isMagnified ? 0.9 : 1
        }
    }

    /// Something is held over this item: an application shows a folder square behind it, 10 % larger,
    /// and dims; both blink twice after 0.65 s (`-[ECSBItemLayer setHighlighted:]`, `0x1000608F8`, and
    /// `-[ECSBGroupItemLayer setHighlighted:]`, `0x1000771C4`). Ending it takes the look away at once.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            updateDropTarget()
        }
    }

    /// Ends a folder's drop-target look once an icon was dropped into it: the square shrinks back from
    /// the whole icon at 1.1 times and the title fades in, with the default animation, and the thumbnails
    /// stay scrolled to the new one (`-[ECSBOpenGroupDragState endDrag:withEvent:]`, 15.5 `0x100085E04`).
    func endDropTargetAfterDrop() {
        guard isDropTarget, isFolder, let backdropLayer else {
            isDropTarget = false
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.removeAnimation(forKey: "blink")
        CATransaction.commit()
        let backdropFrame = folderBackdropFrame
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        // Bounds and position rather than the frame, which is undefined under the 1.1 scale.
        backdropLayer.bounds = CGRect(origin: .zero, size: backdropFrame.size)
        backdropLayer.position = CGPoint(x: backdropFrame.midX, y: backdropFrame.midY)
        backdropLayer.transform = CATransform3DIdentity
        labelLayer.opacity = 1
        CATransaction.commit()
        // Record the end without the instant change `isDropTarget` makes.
        isSuppressingDropTargetUpdate = true
        isDropTarget = false
        isSuppressingDropTargetUpdate = false
    }

    private var isSuppressingDropTargetUpdate = false

    private func updateDropTarget() {
        guard !isSuppressingDropTargetUpdate else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelLayer.opacity = isDropTarget ? 0 : 1
        if isFolder {
            backdropLayer?.removeAnimation(forKey: "blink")
            backdropLayer?.frame = isDropTarget ? iconFrame : folderBackdropFrame
            backdropLayer?.transform = isDropTarget ? CATransform3DMakeScale(1.1, 1.1, 1) : CATransform3DIdentity
            if isDropTarget, let backdropLayer {
                Self.addBlinkAnimation(to: backdropLayer)
            }
            // The thumbnails scroll to the free slot, with the default animation.
            CATransaction.begin()
            CATransaction.setDisableActions(false)
            scrollThumbnails(toAvailableSpace: isDropTarget)
            CATransaction.commit()
        } else if isDropTarget {
            imageLayer.filters = Self.darkeningFilters()
            let newBackdropLayer = CALayer()
            newBackdropLayer.backgroundColor = Self.folderBackdropColor
            newBackdropLayer.cornerCurve = .continuous
            let newTintLayer = CALayer()
            newTintLayer.backgroundColor = Self.dropTargetTintColor
            newTintLayer.compositingFilter = QuartzCorePrivate.stringConstant(named: "kCAFilterDarkenBlendMode")
            newTintLayer.cornerCurve = .continuous
            for layer in [newBackdropLayer, newTintLayer] {
                layer.frame = folderBackdropFrame
                layer.cornerRadius = folderCornerRadius
                layer.transform = CATransform3DMakeScale(1.1, 1.1, 1)
                jitterLayer.insertSublayer(layer, below: imageGroupLayer)
                Self.addBlinkAnimation(to: layer)
            }
            backdropLayer = newBackdropLayer
            dropTargetTintLayer = newTintLayer
        } else {
            imageLayer.filters = isDarkened ? Self.darkeningFilters() : nil
            backdropLayer?.removeFromSuperlayer()
            backdropLayer = nil
            dropTargetTintLayer?.removeFromSuperlayer()
            dropTargetTintLayer = nil
        }
        CATransaction.commit()
    }

    /// Opacity 1 → 0.4 and back, twice, 0.11 s each way, starting 0.65 s from now.
    private static func addBlinkAnimation(to layer: CALayer) {
        let blinkAnimation = CABasicAnimation(keyPath: "opacity")
        blinkAnimation.fromValue = 1
        blinkAnimation.toValue = 0.4
        blinkAnimation.duration = 0.11
        blinkAnimation.autoreverses = true
        blinkAnimation.repeatCount = 2
        blinkAnimation.beginTime = CACurrentMediaTime() + 0.65
        layer.add(blinkAnimation, forKey: "blink")
    }

    // MARK: - Selection

    /// The keyboard selection: icon and title together, widened as 15's `_selectionFrame`
    /// (`0x1000620E4`) widened them, and reaching 15 points above the icon.
    private var selectionFrame: CGRect {
        let iconWidth = imageLayer.frame.width
        let labelWidth = labelLayer.frame.width
        let horizontalOutset: CGFloat
        if labelWidth <= iconWidth {
            horizontalOutset = 15
        } else if labelWidth < iconWidth + 15 {
            horizontalOutset = 7 + max(0, 8 - floor((labelWidth - iconWidth) / 2))
        } else {
            horizontalOutset = 7
        }
        var frame = imageLayer.frame.union(labelLayer.frame).insetBy(dx: -horizontalOutset, dy: -5)
        frame.size.height += 10
        return frame
    }

    private func updateSelection() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isSelected {
            let newSelectionLayer = CALayer()
            newSelectionLayer.backgroundColor = CGColor(gray: 0, alpha: 0.14)
            SpringboardHostSystem.layerFactory.applySelectionMaterial(to: newSelectionLayer)
            // 15 put it at index 0 of the jitter layer, under the icon and its title.
            jitterLayer.insertSublayer(newSelectionLayer, at: 0)
            selectionLayer = newSelectionLayer
            setNeedsLayout()
            layoutIfNeeded()
        } else {
            selectionLayer?.removeFromSuperlayer()
            selectionLayer = nil
        }
        CATransaction.commit()
    }
}

/// Launchpad's images, still inside macOS 27's Dock.app (`ecsb_*`, `ectl_*`).
enum SpringboardTextures {
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]

    /// The `@2x` file on Retina displays, as `ECMultiScaleImage` would pick it, from the host's resource
    /// bundle: the Dock's, inside the Dock and out of it.
    static func image(named name: String, scale: CGFloat) -> CGImage? {
        let fileName = scale > 1 ? "\(name)@2x" : name
        if let cachedImage = cache[fileName] {
            return cachedImage
        }
        guard
            let resourceBundle = SpringboardHostSystem.host.resourceBundle,
            let image = image(named: name, scale: scale, in: resourceBundle)
        else { return nil }
        cache[fileName] = image
        return image
    }

    /// The image from `bundle`, uncached: the `@2x` file on Retina displays, the plain one otherwise or
    /// when there is no `@2x`.
    static func image(named name: String, scale: CGFloat, in bundle: Bundle) -> CGImage? {
        let fileName = scale > 1 ? "\(name)@2x" : name
        guard
            let imageURL = bundle.url(forResource: fileName, withExtension: "png") ?? bundle.url(forResource: name, withExtension: "png"),
            let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }
}

extension CALayer {
    /// Puts the layer over `frame`, a rectangle in its superlayer, as if it had no transform. Unlike
    /// setting `frame`, this means the same whatever the transform is: setting the frame of a layer scaled
    /// to a tenth makes it ten times as large once the scale goes.
    func setUntransformedFrame(_ frame: CGRect) {
        bounds = CGRect(origin: bounds.origin, size: frame.size)
        position = CGPoint(x: frame.minX + anchorPoint.x * frame.width, y: frame.minY + anchorPoint.y * frame.height)
    }
}

extension CATextLayer {
    /// Makes a new string show at once, as a text field shows what is typed. Core Animation otherwise
    /// cross-fades a text layer's redrawn contents over a quarter of a second, so a centred name being
    /// typed showed the old and the new string half a character apart after every key.
    func disableTextCrossfade() {
        var textActions = actions ?? [:]
        textActions["contents"] = NSNull()
        actions = textActions
    }
}
