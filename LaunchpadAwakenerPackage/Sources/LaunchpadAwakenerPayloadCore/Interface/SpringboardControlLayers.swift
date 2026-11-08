import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// The page dots; macOS 15's `ECPagerControlLayer` with one `ECPagerIndicatorLayer` per page.
///
/// 8-point white dots, the current one opaque and the rest at 20 %, hidden when there is only one page
/// (`pagerControlVisibility` 2). The colour change rides the page-change transaction, so it fades with
/// the scroll.
final class SpringboardPagerControlLayer: CALayer {
    private var dotLayers: [CALayer] = []
    private var indicatorFrames: [CGRect] = []

    override init() {
        super.init()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(pageCount: Int, currentPageIndex: Int, metrics: SpringboardMetrics) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = pageCount <= 1
        while dotLayers.count < pageCount {
            let dotLayer = CALayer()
            dotLayer.cornerRadius = SpringboardMetrics.pagerDotSide / 2
            addSublayer(dotLayer)
            dotLayers.append(dotLayer)
        }
        while dotLayers.count > pageCount {
            dotLayers.removeLast().removeFromSuperlayer()
        }
        indicatorFrames = (0..<pageCount).map { metrics.pagerIndicatorFrame(at: $0, pageCount: pageCount) }
        for (indicatorIndex, dotLayer) in dotLayers.enumerated() {
            dotLayer.frame = metrics.pagerDotFrame(inIndicatorFrame: indicatorFrames[indicatorIndex])
        }
        CATransaction.commit()
        setCurrentPageIndex(currentPageIndex)
    }

    /// Recolours the dots inside the caller's transaction.
    func setCurrentPageIndex(_ currentPageIndex: Int) {
        for (indicatorIndex, dotLayer) in dotLayers.enumerated() {
            dotLayer.backgroundColor = CGColor(gray: 1, alpha: indicatorIndex == currentPageIndex ? 1 : 0.2)
        }
    }

    /// The page whose indicator is under `point`, a point in this layer.
    func pageIndex(at point: CGPoint) -> Int? {
        guard !isHidden else { return nil }
        return indicatorFrames.firstIndex { $0.contains(point) }
    }
}

/// The search field; macOS 15's `ECTextInputLayer`, drawn locally.
///
/// 15 hosted a real text field from another process; here the Dock's key events are turned into text,
/// which means no input method — see the decision log. Looks follow 15: the capsule `ectl_search_background`,
/// the loupe and the placeholder centred together until the field is clicked into or typed in, then the
/// loupe at the left, the text after it and the clear button at the right (`-[ECTextInputLayer layout]`,
/// `0x1000086F0`). With the focus, a white caret blinks after the text, as the hosted field's did.
final class SpringboardSearchFieldLayer: CALayer {
    static let loupeSide: CGFloat = 12
    static let clearButtonSide: CGFloat = 14
    /// Where the text starts once the field is active: the loupe at 7, 12 wide, then 8.
    static let textOriginX: CGFloat = 27

    private let backgroundLayer = CALayer()
    private let loupeLayer = CALayer()
    private let placeholderLayer = DockLayerFactory.makeTextLayer(withShadow: false)
    let textLayer = DockLayerFactory.makeTextLayer(withShadow: false)
    private let clearButtonLayer = CALayer()
    private let caretLayer = CALayer()

    override init() {
        super.init()
        backgroundLayer.contentsCenter = CGRect(x: 0.5, y: 0, width: 0, height: 1)
        loupeLayer.contentsGravity = .resizeAspect
        clearButtonLayer.contentsGravity = .resizeAspect
        clearButtonLayer.opacity = 0.3
        for textLayerToStyle in [placeholderLayer, textLayer] {
            textLayerToStyle.font = SpringboardTypography.searchFont
            textLayerToStyle.fontSize = CTFontGetSize(SpringboardTypography.searchFont)
            textLayerToStyle.alignmentMode = .left
            textLayerToStyle.truncationMode = .start
        }
        placeholderLayer.foregroundColor = CGColor(gray: 1, alpha: 0.36)
        placeholderLayer.string = SpringboardStrings.search
        textLayer.foregroundColor = CGColor(gray: 1, alpha: 1)
        textLayer.disableTextCrossfade()
        caretLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
        caretLayer.isHidden = true
        for sublayer in [backgroundLayer, loupeLayer, placeholderLayer, textLayer, clearButtonLayer, caretLayer] {
            addSublayer(sublayer)
        }
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private(set) var text = ""
    /// The first layout places everything; only later ones animate between the two arrangements.
    private var hasLaidOut = false

    /// Clicked into or typed in: the loupe and the placeholder sit at the left even with nothing typed
    /// (`-[ECTextInputLayer setTextFieldActive:]`, 15.5 `0x100031700`).
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Typing goes to the field, shown by the blinking caret.
    var hasFocus = false {
        didSet {
            guard hasFocus != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            caretLayer.isHidden = !hasFocus
            CATransaction.commit()
            restartBlinking()
            setNeedsLayout()
        }
    }

    /// Shown in full at once, as after each key typed, then blinking.
    private func restartBlinking() {
        caretLayer.removeAnimation(forKey: "blink")
        guard hasFocus else { return }
        let blinkAnimation = CABasicAnimation(keyPath: "opacity")
        blinkAnimation.fromValue = 1
        blinkAnimation.toValue = 0
        blinkAnimation.duration = 0.5
        blinkAnimation.autoreverses = true
        blinkAnimation.repeatCount = .infinity
        caretLayer.add(blinkAnimation, forKey: "blink")
    }

    func configure(scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentsScale = scale
        backgroundLayer.contents = SpringboardTextures.image(named: "ectl_search_background", scale: scale)
        loupeLayer.contents = SpringboardTextures.image(named: "ectl_search_loupe", scale: scale)
        clearButtonLayer.contents = SpringboardTextures.image(named: "ectl_search_close", scale: scale)
        for sublayer in [backgroundLayer, loupeLayer, placeholderLayer, textLayer, clearButtonLayer] {
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
        setText("")
    }

    /// Shows `newText`; the layout animates between the empty and the active arrangement as 15's did.
    func setText(_ newText: String) {
        text = newText
        textLayer.string = newText
        placeholderLayer.isHidden = !newText.isEmpty
        clearButtonLayer.isHidden = newText.isEmpty
        restartBlinking()
        setNeedsLayout()
    }

    /// Whether `point`, a point in this layer, is on the clear button.
    func isOnClearButton(_ point: CGPoint) -> Bool {
        !clearButtonLayer.isHidden && clearButtonLayer.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    var isClearButtonPressed = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clearButtonLayer.opacity = isClearButtonPressed ? 1 : 0.3
            CATransaction.commit()
        }
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        let width = bounds.width
        let height = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        let textHeight = SpringboardTypography.lineHeight(of: SpringboardTypography.searchFont)
        let loupeY = (height / 2 - 5).rounded() - 1
        clearButtonLayer.frame = CGRect(
            x: width - 20,
            y: (height / 2 - 6).rounded() - 1,
            width: Self.clearButtonSide,
            height: Self.clearButtonSide
        )
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setDisableActions(!hasLaidOut)
        hasLaidOut = true
        let textWidth = width - Self.textOriginX - 25
        if text.isEmpty, !isActive {
            let placeholderWidth = SpringboardTypography.width(of: SpringboardStrings.search, in: SpringboardTypography.searchFont)
            let placeholderX = width / 2 - placeholderWidth / 2 + 12
            placeholderLayer.frame = CGRect(x: placeholderX, y: 4, width: placeholderWidth + 2, height: textHeight)
            loupeLayer.frame = CGRect(x: placeholderX - 20, y: loupeY, width: Self.loupeSide, height: Self.loupeSide)
        } else {
            placeholderLayer.frame = CGRect(x: Self.textOriginX, y: 4, width: textWidth, height: textHeight)
            loupeLayer.frame = CGRect(x: 7, y: loupeY, width: Self.loupeSide, height: Self.loupeSide)
        }
        textLayer.frame = CGRect(x: Self.textOriginX, y: 4, width: textWidth, height: textHeight)
        CATransaction.commit()

        // 2 points wide and 19 high, inset 3 from top and bottom, as macOS 15.5 shows it, after the text.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let typedWidth = min(SpringboardTypography.width(of: text, in: SpringboardTypography.searchFont), textWidth)
        caretLayer.frame = CGRect(x: Self.textOriginX - 1 + typedWidth, y: 3, width: 2, height: height - 6)
        CATransaction.commit()
    }
}

/// "No Results", in 15's large grey shadowed type over the page area.
final class SpringboardNoResultsLayer: CALayer {
    private let textLayer = DockLayerFactory.makeTextLayer(withShadow: true)

    override init() {
        super.init()
        textLayer.string = SpringboardStrings.noResults
        textLayer.font = SpringboardTypography.noResultsFont
        textLayer.fontSize = CTFontGetSize(SpringboardTypography.noResultsFont)
        textLayer.foregroundColor = CGColor(red: 0.2039, green: 0.2039, blue: 0.2039, alpha: 1)
        textLayer.alignmentMode = .center
        textLayer.compositingFilter = QuartzCorePrivate.stringConstant(named: "kCAFilterPlusL")
        DockLayerFactory.setTextShadow(of: textLayer, color: CGColor(gray: 0, alpha: 0.2), offset: CGSize(width: 0, height: -1), blur: 2)
        // Core Animation's private `allowsGroupBlending`, which 15 turned off for this container.
        setValue(false, forKey: "allowsGroupBlending")
        addSublayer(textLayer)
        opacity = 0
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Centres the text in `pageFrame`, sized to the text plus 10 points.
    func layout(in pageFrame: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contentsScale = scale
        let textSize = CGSize(
            width: SpringboardTypography.width(of: SpringboardStrings.noResults, in: SpringboardTypography.noResultsFont) + 10,
            height: SpringboardTypography.lineHeight(of: SpringboardTypography.noResultsFont) + 10
        )
        frame = CGRect(
            x: (pageFrame.midX - textSize.width / 2).rounded(),
            y: (pageFrame.midY - textSize.height / 2).rounded(),
            width: textSize.width,
            height: textSize.height
        )
        textLayer.frame = bounds
        CATransaction.commit()
    }
}
