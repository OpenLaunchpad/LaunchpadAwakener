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
/// 15 hosted a real text field from another process; here the Dock's key events are edited with
/// ``SpringboardFieldEditor``, which means no input method — see the decision log. Looks follow 15: the
/// capsule `ectl_search_background`, the loupe and the placeholder centred together until the field is
/// clicked into or typed in, then the loupe at the left, the text after it and the clear button at the
/// right (`-[ECTextInputLayer layout]`, `0x1000086F0`). With the focus, a white caret blinks where it
/// stands, or the selection shows; text wider than the field scrolls to keep the caret in view, as the
/// hosted field's did.
final class SpringboardSearchFieldLayer: CALayer {
    static let loupeSide: CGFloat = 12
    static let clearButtonSide: CGFloat = 14
    /// Where the text starts once the field is active: the loupe at 7, 12 wide, then 8.
    static let textOriginX: CGFloat = 27

    private let backgroundLayer = CALayer()
    private let loupeLayer = CALayer()
    private let placeholderLayer = SpringboardHostSystem.layerFactory.makeTextLayer(withShadow: false)
    let textLayer = SpringboardHostSystem.layerFactory.makeTextLayer(withShadow: false)
    private let clearButtonLayer = CALayer()
    /// The typed text's area, which clips it once it scrolls.
    private let clippingLayer = CALayer()
    private let selectionLayer = CALayer()
    private let caretLayer = CALayer()
    private(set) var editing = SpringboardTextEditing(selectingAllOf: "")
    private var textLine = SpringboardTextLine(text: "", font: SpringboardTypography.searchFont)
    /// How far the text has scrolled to the left, once it is wider than its area.
    private var scrollOffset: CGFloat = 0
    /// Where the line starts in the clipping layer, as last laid out.
    private var lineStartX: CGFloat = 0

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
        // Placed by hand, so that the caret and the selection fall exactly between its characters.
        textLayer.truncationMode = .none
        textLayer.isWrapped = false
        textLayer.disableTextCrossfade()
        caretLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
        caretLayer.isHidden = true
        selectionLayer.backgroundColor = SpringboardTitleEditorLayer.selectionColor
        selectionLayer.isHidden = true
        clippingLayer.masksToBounds = true
        clippingLayer.addSublayer(selectionLayer)
        clippingLayer.addSublayer(textLayer)
        clippingLayer.addSublayer(caretLayer)
        for sublayer in [backgroundLayer, loupeLayer, placeholderLayer, clippingLayer, clearButtonLayer] {
            addSublayer(sublayer)
        }
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    var text: String {
        editing.text
    }

    /// The text area's size for a field `fieldSize` big: what the text input helper's field fills.
    static func hostedTextAreaSize(forFieldSize fieldSize: CGSize) -> CGSize {
        CGSize(width: fieldSize.width - textOriginX - 25 + 2, height: fieldSize.height)
    }

    /// The text area of a field at `fieldFrame`, in the same coordinates: where the hosted field goes.
    static func hostedTextAreaFrame(inFieldFrame fieldFrame: CGRect) -> CGRect {
        CGRect(
            origin: CGPoint(x: fieldFrame.minX + textOriginX - 1, y: fieldFrame.minY),
            size: hostedTextAreaSize(forFieldSize: fieldFrame.size)
        )
    }

    /// The text area in this layer's coordinates.
    var hostedTextAreaFrame: CGRect {
        Self.hostedTextAreaFrame(inFieldFrame: bounds)
    }

    /// The field as the text input helper hosts it, for input methods. While it is set it shows the text,
    /// the caret and the selection; this layer keeps the capsule, the loupe, the placeholder and the clear
    /// button.
    var hostedTextLayer: CALayer? {
        didSet {
            guard hostedTextLayer !== oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            oldValue?.removeFromSuperlayer()
            if let hostedTextLayer {
                hostedTextLayer.frame = hostedTextAreaFrame
                insertSublayer(hostedTextLayer, below: clearButtonLayer)
            }
            clippingLayer.isHidden = hostedTextLayer != nil
            CATransaction.commit()
        }
    }

    /// An input method is composing text in the hosted field: the placeholder keeps out of its way.
    var isComposingInHostedField = false {
        didSet {
            guard isComposingInHostedField != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            placeholderLayer.isHidden = !editing.text.isEmpty || isComposingInHostedField
            CATransaction.commit()
        }
    }

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

    /// Typing goes to the field, shown by the blinking caret or the selection.
    var hasFocus = false {
        didSet {
            guard hasFocus != oldValue else { return }
            updateCaretAndSelectionVisibility()
            restartBlinking()
            setNeedsLayout()
        }
    }

    private func updateCaretAndSelectionVisibility() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caretLayer.isHidden = !hasFocus || editing.hasSelection
        selectionLayer.isHidden = !hasFocus || !editing.hasSelection
        CATransaction.commit()
    }

    /// Shown in full at once, as after each key typed, then blinking.
    private func restartBlinking() {
        caretLayer.removeAnimation(forKey: "blink")
        guard hasFocus, !editing.hasSelection else { return }
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
        show(SpringboardTextEditing(selectingAllOf: ""))
    }

    /// Shows `newEditing`: its text, and its caret or selection. The layout animates between the empty
    /// and the active arrangement as 15's did.
    func show(_ newEditing: SpringboardTextEditing) {
        if newEditing.text != editing.text || textLayer.string == nil {
            textLayer.string = newEditing.text
            textLine = SpringboardTextLine(text: newEditing.text, font: SpringboardTypography.searchFont)
        }
        editing = newEditing
        placeholderLayer.isHidden = !newEditing.text.isEmpty || isComposingInHostedField
        clearButtonLayer.isHidden = newEditing.text.isEmpty
        updateCaretAndSelectionVisibility()
        restartBlinking()
        setNeedsLayout()
    }

    /// Where a click at `point`, a point in this layer, puts the caret.
    func caretOffset(at point: CGPoint) -> Int {
        layoutIfNeeded()
        return textLine.caretOffset(nearestTo: point.x - clippingLayer.frame.minX - lineStartX)
    }

    /// The character under `point`, a point in this layer, whose word a double-click selects.
    func characterOffset(at point: CGPoint) -> Int {
        layoutIfNeeded()
        return textLine.characterOffset(at: point.x - clippingLayer.frame.minX - lineStartX)
    }

    /// Where a line starts in an area `areaWidth` wide, and how far it has scrolled: at the area's start
    /// while it fits, and otherwise scrolled from `scrollOffset` by as little as keeps the caret, `caretX`
    /// from the start of the line, in view.
    static func linePlacement(lineWidth: CGFloat, caretX: CGFloat, areaWidth: CGFloat, scrollOffset: CGFloat) -> (lineStartX: CGFloat, scrollOffset: CGFloat) {
        let caretWidth = SpringboardTitleEditorLayer.caretWidth
        guard lineWidth + caretWidth > areaWidth else { return (0, 0) }
        let caretInViewOffset = min(max(scrollOffset, caretX + caretWidth - areaWidth), caretX)
        let newScrollOffset = min(max(caretInViewOffset, 0), lineWidth + caretWidth - areaWidth)
        return (-newScrollOffset.rounded(), newScrollOffset)
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
        hostedTextLayer?.frame = hostedTextAreaFrame
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
        CATransaction.commit()

        // The caret is 2 points wide and 19 high, inset 3 from top and bottom, as macOS 15.5 shows it; the
        // selection stands as tall.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clippingLayer.frame = CGRect(x: Self.textOriginX - 1, y: 3, width: textWidth + 2, height: height - 6)
        let caretX = textLine.caretXOffsets[min(editing.caretOffset, textLine.caretXOffsets.count - 1)]
        (lineStartX, scrollOffset) = Self.linePlacement(lineWidth: textLine.width, caretX: caretX, areaWidth: textWidth, scrollOffset: scrollOffset)
        let textStartX = 1 + lineStartX
        textLayer.frame = CGRect(x: textStartX, y: 1, width: ceil(textLine.width) + SpringboardTitleEditorLayer.caretWidth, height: textHeight)
        caretLayer.frame = CGRect(x: textStartX + caretX - 1, y: 0, width: 2, height: clippingLayer.bounds.height)
        let selectionStartX = textLine.caretXOffsets[min(editing.selectedRange.lowerBound, textLine.caretXOffsets.count - 1)]
        let selectionEndX = textLine.caretXOffsets[min(editing.selectedRange.upperBound, textLine.caretXOffsets.count - 1)]
        selectionLayer.frame = CGRect(x: textStartX + selectionStartX, y: 0, width: selectionEndX - selectionStartX, height: clippingLayer.bounds.height)
        CATransaction.commit()
    }
}

/// "No Results", in 15's large grey shadowed type over the page area.
final class SpringboardNoResultsLayer: CALayer {
    private let textLayer = SpringboardHostSystem.layerFactory.makeTextLayer(withShadow: true)

    override init() {
        super.init()
        textLayer.string = SpringboardStrings.noResults
        textLayer.font = SpringboardTypography.noResultsFont
        textLayer.fontSize = CTFontGetSize(SpringboardTypography.noResultsFont)
        textLayer.foregroundColor = CGColor(red: 0.2039, green: 0.2039, blue: 0.2039, alpha: 1)
        textLayer.alignmentMode = .center
        textLayer.compositingFilter = QuartzCorePrivate.stringConstant(named: "kCAFilterPlusL")
        SpringboardHostSystem.layerFactory.setTextShadow(of: textLayer, color: CGColor(gray: 0, alpha: 0.2), offset: CGSize(width: 0, height: -1), blur: 2)
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
