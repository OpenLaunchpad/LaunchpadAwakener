import CoreGraphics
import CoreText
import Foundation
import ImageIO
import QuartzCore

/// An icon title; macOS 15's `ECSBLabelLayer`, which drew with the Dock's `ECShadowTextLayer`.
///
/// White Medium 13, middle truncation, a black 20 % shadow 1 point down with a 2-point blur
/// (15.5 `-[ECSBLabelLayer initWithString:andScaleFactor:]`, `0x10001FD60`). The text sits 2 points
/// inside the label on every side.
final class SpringboardLabelLayer: CALayer {
    static let textInset: CGFloat = 2

    let textLayer: CATextLayer = DockLayerFactory.makeTextLayer(withShadow: true)

    override init() {
        super.init()
        textLayer.font = SpringboardTypography.labelFont
        textLayer.fontSize = CTFontGetSize(SpringboardTypography.labelFont)
        textLayer.foregroundColor = CGColor(gray: 1, alpha: 1)
        textLayer.truncationMode = .middle
        textLayer.alignmentMode = .center
        DockLayerFactory.setTextShadow(of: textLayer, color: CGColor(gray: 0, alpha: 0.2), offset: CGSize(width: 0, height: -1), blur: 2)
        addSublayer(textLayer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setString(_ string: String, contentsScale scale: CGFloat) {
        textLayer.string = string
        textLayer.contentsScale = scale
        contentsScale = scale
    }

    /// `(text width + 4, line height + 7)`: the inset on both sides, plus room for the blur and the
    /// downward offset of the shadow (`-[ECSBLabelLayer preferredFrameSize]`, `0x1000210F0`).
    static func preferredSize(of string: String) -> CGSize {
        CGSize(
            width: SpringboardTypography.width(of: string, in: SpringboardTypography.labelFont) + 2 * textInset,
            height: SpringboardTypography.lineHeight(of: SpringboardTypography.labelFont) + 7
        )
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.frame = bounds.insetBy(dx: Self.textInset, dy: Self.textInset)
        CATransaction.commit()
    }
}

/// One cell of a page: an application or a folder with its title; macOS 15's `ECSBItemLayer`.
///
/// Positioned by the Dock's `ECGridLayer`, which sets each item's bounds to a whole cell; this lays the
/// icon and title out inside the cell (`-[ECSBItemLayer layout]`, 15.5 `0x100020A14`).
final class SpringboardItemLayer: CALayer {
    private(set) var item: LaunchpadItem?
    private var metrics: SpringboardMetrics?

    let imageLayer = CALayer()
    let labelLayer = SpringboardLabelLayer()
    private var selectionLayer: CALayer?
    private var folderThumbnailLayers: [CALayer] = []

    override init() {
        super.init()
        imageLayer.contentsGravity = .resizeAspect
        addSublayer(imageLayer)
        addSublayer(labelLayer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The icon, in this layer: only a press on it counts as a press on the item, as in 15.
    private(set) var iconFrame: CGRect = .zero

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateSelection()
        }
    }

    /// Pressed: the icon dims to 40 % (`-[ECSBItemLayer setDarkened:]`, `0x100060DA8`).
    var isDarkened = false {
        didSet {
            guard isDarkened != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if isDarkened, let multiplyFilterType = QuartzCorePrivate.stringConstant(named: "kCAFilterMultiplyColor"),
               let darkeningFilter = QuartzCorePrivate.makeFilter(type: multiplyFilterType)
            {
                darkeningFilter.setValue(CGColor(gray: 0.4, alpha: 1), forKey: "inputColor")
                imageLayer.filters = [darkeningFilter]
            } else {
                imageLayer.filters = nil
            }
            CATransaction.commit()
        }
    }

    func configure(with item: LaunchpadItem, metrics: SpringboardMetrics, scale: CGFloat) {
        self.item = item
        self.metrics = metrics
        contentsScale = scale
        imageLayer.contentsScale = scale
        labelLayer.setString(item.title, contentsScale: scale)
        switch item {
        case .application:
            folderThumbnailLayers.forEach { $0.removeFromSuperlayer() }
            folderThumbnailLayers = []
        case .folder(let folder):
            imageLayer.contents = SpringboardTextures.image(named: "ecsb_group", scale: scale)
            let thumbnailCount = min(folder.applications.count, 9)
            while folderThumbnailLayers.count < thumbnailCount {
                let thumbnailLayer = CALayer()
                thumbnailLayer.contentsGravity = .resizeAspect
                thumbnailLayer.contentsScale = scale
                addSublayer(thumbnailLayer)
                folderThumbnailLayers.append(thumbnailLayer)
            }
            while folderThumbnailLayers.count > thumbnailCount {
                folderThumbnailLayers.removeLast().removeFromSuperlayer()
            }
        }
        setNeedsLayout()
    }

    /// An application's icon, with the compositing filter the Dock gives icons in the current style.
    func setApplicationIcon(_ icon: CGImage?, compositingFilterName: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = icon
        imageLayer.compositingFilter = compositingFilterName
        CATransaction.commit()
    }

    /// The icons of a folder's first nine applications, in reading order.
    func setFolderThumbnails(_ thumbnails: [CGImage?]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (thumbnailLayer, thumbnail) in zip(folderThumbnailLayers, thumbnails) {
            thumbnailLayer.contents = thumbnail
        }
        CATransaction.commit()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
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
        imageLayer.frame = iconFrame

        let preferredLabelSize = SpringboardLabelLayer.preferredSize(of: item.title)
        let labelWidth = min(preferredLabelSize.width, metrics.labelMaximumWidth)
        labelLayer.frame = CGRect(
            x: Self.centered(cellWidth / 2 - labelWidth / 2, isEven: Int(labelWidth).isMultiple(of: 2)),
            y: bottomPadding,
            width: labelWidth,
            height: metrics.labelHeight
        )

        layoutFolderThumbnails()
        if let selectionLayer {
            selectionLayer.frame = selectionFrame
            selectionLayer.cornerRadius = Self.selectionCornerRadius(forIconSide: iconSide)
        }
        CATransaction.commit()
    }

    /// 15 truncated even sizes and rounded odd ones when centring.
    private static func centered(_ origin: CGFloat, isEven: Bool) -> CGFloat {
        isEven ? origin.rounded(.towardZero) : origin.rounded()
    }

    private func layoutFolderThumbnails() {
        guard !folderThumbnailLayers.isEmpty else { return }
        let inset = (iconFrame.width * 0.14).rounded()
        let cellSide = (iconFrame.width - 2 * inset) / 3
        let thumbnailSide = (cellSide * 0.82).rounded()
        for (thumbnailIndex, thumbnailLayer) in folderThumbnailLayers.enumerated() {
            let row = thumbnailIndex / 3
            let column = thumbnailIndex % 3
            thumbnailLayer.frame = CGRect(
                x: iconFrame.minX + inset + CGFloat(column) * cellSide + (cellSide - thumbnailSide) / 2,
                y: iconFrame.maxY - inset - CGFloat(row + 1) * cellSide + (cellSide - thumbnailSide) / 2,
                width: thumbnailSide,
                height: thumbnailSide
            )
        }
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

    /// `round(icon height × 0.15625)`, rounding half down as 15's `sub_10006AF28` did.
    private static func selectionCornerRadius(forIconSide iconSide: CGFloat) -> CGFloat {
        ceil(iconSide * 0.15625 - 0.5)
    }

    private func updateSelection() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isSelected {
            let newSelectionLayer = CALayer()
            newSelectionLayer.backgroundColor = CGColor(gray: 0, alpha: 0.14)
            DockLayerFactory.setMaterialControl(3, appearance: 1, of: newSelectionLayer)
            insertSublayer(newSelectionLayer, at: 0)
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

    /// The `@2x` file on Retina displays, as `ECMultiScaleImage` would pick it.
    static func image(named name: String, scale: CGFloat) -> CGImage? {
        let fileName = scale > 1 ? "\(name)@2x" : name
        if let cachedImage = cache[fileName] {
            return cachedImage
        }
        guard
            let imageURL = Bundle.main.url(forResource: fileName, withExtension: "png") ?? Bundle.main.url(forResource: name, withExtension: "png"),
            let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return nil }
        cache[fileName] = image
        return image
    }
}
