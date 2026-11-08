import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// The confirmation macOS 15 asked for before deleting an application: a popover under the icon from the
/// Dock's `com.apple.dock.ecap` service, with the icon, the question, Cancel, and Delete as the default
/// button. 27's Dock no longer has that service, so this draws it with layers in the springboard. The
/// content is the service's 400 × 84 view: the icon 64 points at 10, 10 from the top left, the question
/// in 13-point text beside it, the buttons at the bottom right. Nothing behind it dims; while it shows it
/// takes every click and key (`-[ECAlertPanel keyDown:]`, 15.5 `0x10007BD04`).
final class SpringboardDeletionPanel: CALayer {
    enum Choice: Sendable, Equatable {
        case delete
        case cancel

        /// Return and Enter delete; Escape and Command-period cancel; nil for any other key.
        init?(keyCode: Int64, characters: String, hasCommand: Bool) {
            switch keyCode {
            case SpringboardKeyCode.returnKey, SpringboardKeyCode.keypadEnter:
                self = .delete
            case SpringboardKeyCode.escape:
                self = .cancel
            default:
                guard hasCommand, characters == "." else { return nil }
                self = .cancel
            }
        }
    }

    static let bodySize = CGSize(width: 400, height: 84)
    static let arrowHeight: CGFloat = 13
    static let arrowHalfWidth: CGFloat = 13
    static let cornerRadius: CGFloat = 10
    /// How close to the screen's edges the popover may come.
    static let screenMargin: CGFloat = 10
    private static let iconSide: CGFloat = 64
    private static let contentInset: CGFloat = 10
    private static let messageMaximumWidth: CGFloat = 304
    private static let buttonHeight: CGFloat = 22
    private static let buttonInset: CGFloat = 12

    /// Where the popover goes for an icon centred at `iconCenter`: under a 20 × 20 rectangle on the
    /// icon's centre, NSPopover's bottom edge as the service asked for, kept on the screen.
    struct Layout: Sendable, Equatable {
        /// The rounded body, in the container.
        let bodyFrame: CGRect
        let arrowTip: CGPoint

        init(iconCenter: CGPoint, containerBounds: CGRect) {
            let arrowTip = CGPoint(x: iconCenter.x, y: iconCenter.y - 10)
            let lowestX = containerBounds.minX + SpringboardDeletionPanel.screenMargin
            let highestX = containerBounds.maxX - SpringboardDeletionPanel.screenMargin - SpringboardDeletionPanel.bodySize.width
            bodyFrame = CGRect(
                x: min(max(iconCenter.x - SpringboardDeletionPanel.bodySize.width / 2, lowestX), highestX),
                y: arrowTip.y - SpringboardDeletionPanel.arrowHeight - SpringboardDeletionPanel.bodySize.height,
                width: SpringboardDeletionPanel.bodySize.width,
                height: SpringboardDeletionPanel.bodySize.height
            )
            self.arrowTip = arrowTip
        }
    }

    /// The application being asked about, and where its icon is.
    struct Target {
        let application: LaunchpadApplication
        let context: SpringboardInterface.GridContext
        weak var itemLayer: SpringboardItemLayer?
    }

    /// Nil only on the copies Core Animation makes to animate.
    let target: Target?

    private let bubbleLayer = CAShapeLayer()
    private let iconLayer = CALayer()
    private let messageLayer = CATextLayer()
    private let cancelButtonLayer = CALayer()
    private let deleteButtonLayer = CALayer()

    init(application: LaunchpadApplication, itemLayer: SpringboardItemLayer, context: SpringboardInterface.GridContext, layout: Layout, scale: CGFloat) {
        target = Target(application: application, context: context, itemLayer: itemLayer)
        super.init()
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let textColor = isDark ? CGColor(gray: 1, alpha: 0.9) : CGColor(gray: 0, alpha: 0.85)
        let font = CTFontCreateUIFontForLanguage(.system, 13, nil) ?? SpringboardTypography.labelFont
        contentsScale = scale
        frame = CGRect(
            x: layout.bodyFrame.minX,
            y: layout.bodyFrame.minY,
            width: Self.bodySize.width,
            height: Self.bodySize.height + Self.arrowHeight
        )

        bubbleLayer.path = Self.bubblePath(arrowTipX: layout.arrowTip.x - layout.bodyFrame.minX)
        bubbleLayer.fillColor = isDark ? CGColor(gray: 0.17, alpha: 0.98) : CGColor(gray: 0.96, alpha: 0.98)
        bubbleLayer.strokeColor = isDark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.1)
        bubbleLayer.lineWidth = 1
        bubbleLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        bubbleLayer.shadowOpacity = 0.3
        bubbleLayer.shadowRadius = 10
        bubbleLayer.shadowOffset = CGSize(width: 0, height: -4)
        addSublayer(bubbleLayer)

        let contentTop = Self.bodySize.height - Self.contentInset
        iconLayer.frame = CGRect(x: Self.contentInset, y: contentTop - Self.iconSide, width: Self.iconSide, height: Self.iconSide)
        iconLayer.contents = itemLayer.imageLayer.contents
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = scale
        addSublayer(iconLayer)

        let messageX = Self.contentInset + Self.iconSide + Self.contentInset
        messageLayer.frame = CGRect(x: messageX, y: Self.buttonInset + Self.buttonHeight + 4, width: Self.messageMaximumWidth, height: contentTop - (Self.buttonInset + Self.buttonHeight + 4))
        messageLayer.string = SpringboardDeletionStrings.message(forApplicationNamed: application.title)
        messageLayer.font = font
        messageLayer.fontSize = CTFontGetSize(font)
        messageLayer.foregroundColor = textColor
        messageLayer.isWrapped = true
        messageLayer.alignmentMode = .left
        messageLayer.contentsScale = scale
        addSublayer(messageLayer)

        let deleteWidth = Self.buttonWidth(for: SpringboardDeletionStrings.delete, font: font)
        let cancelWidth = Self.buttonWidth(for: SpringboardDeletionStrings.cancel, font: font)
        deleteButtonLayer.frame = CGRect(x: Self.bodySize.width - Self.buttonInset - deleteWidth, y: Self.buttonInset, width: deleteWidth, height: Self.buttonHeight)
        cancelButtonLayer.frame = CGRect(x: deleteButtonLayer.frame.minX - 10 - cancelWidth, y: Self.buttonInset, width: cancelWidth, height: Self.buttonHeight)
        Self.styleButton(deleteButtonLayer, title: SpringboardDeletionStrings.delete, font: font, fillColor: CGColor(red: 0, green: 122 / 255, blue: 1, alpha: 1), borderColor: nil, textColor: CGColor(gray: 1, alpha: 1), scale: scale)
        Self.styleButton(
            cancelButtonLayer,
            title: SpringboardDeletionStrings.cancel,
            font: font,
            fillColor: isDark ? CGColor(gray: 0.38, alpha: 1) : CGColor(gray: 1, alpha: 1),
            borderColor: isDark ? nil : CGColor(gray: 0, alpha: 0.15),
            textColor: textColor,
            scale: scale
        )
        addSublayer(cancelButtonLayer)
        addSublayer(deleteButtonLayer)
    }

    override init(layer: Any) {
        target = (layer as? SpringboardDeletionPanel)?.target
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The button under `point`, a point in this layer.
    func choice(at point: CGPoint) -> Choice? {
        if deleteButtonLayer.frame.contains(point) {
            return .delete
        }
        if cancelButtonLayer.frame.contains(point) {
            return .cancel
        }
        return nil
    }

    private static func buttonWidth(for title: String, font: CTFont) -> CGFloat {
        max(ceil(SpringboardTypography.width(of: title, in: font)) + 28, 70)
    }

    private static func styleButton(_ buttonLayer: CALayer, title: String, font: CTFont, fillColor: CGColor, borderColor: CGColor?, textColor: CGColor, scale: CGFloat) {
        buttonLayer.backgroundColor = fillColor
        buttonLayer.cornerRadius = 6
        if let borderColor {
            buttonLayer.borderColor = borderColor
            buttonLayer.borderWidth = 0.5
        }
        let titleLayer = CATextLayer()
        let lineHeight = SpringboardTypography.lineHeight(of: font)
        titleLayer.frame = CGRect(x: 0, y: ((buttonLayer.bounds.height - lineHeight) / 2).rounded(), width: buttonLayer.bounds.width, height: lineHeight)
        titleLayer.string = title
        titleLayer.font = font
        titleLayer.fontSize = CTFontGetSize(font)
        titleLayer.foregroundColor = textColor
        titleLayer.alignmentMode = .center
        titleLayer.contentsScale = scale
        buttonLayer.addSublayer(titleLayer)
    }

    /// The body's rounded rectangle with the arrow on its top edge, `arrowTipX` from its left.
    private static func bubblePath(arrowTipX: CGFloat) -> CGPath {
        let body = CGRect(origin: .zero, size: bodySize)
        let tipX = min(max(arrowTipX, cornerRadius + arrowHalfWidth), body.width - cornerRadius - arrowHalfWidth)
        let path = CGMutablePath()
        path.addRoundedRect(in: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        path.move(to: CGPoint(x: tipX - arrowHalfWidth, y: body.maxY))
        path.addLine(to: CGPoint(x: tipX, y: body.maxY + arrowHeight))
        path.addLine(to: CGPoint(x: tipX + arrowHalfWidth, y: body.maxY))
        path.closeSubpath()
        return path
    }
}
