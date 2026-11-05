import CoreGraphics
import CoreText
import Foundation
import ImageIO
import QuartzCore

/// What the springboard should do after its content handled an event.
enum SpringboardContentAction: Sendable, Equatable {
    case none
    case dismiss(reason: String)
    case launch(bundleIdentifier: String, title: String)
}

/// The prototype's drawing, kept until the main interface is rebuilt on the Dock's `EC*` layers.
///
/// Shows the first page of the layout, or every application matching what has been typed, as plain
/// layers. Clicking an icon launches it, clicking anywhere else dismisses.
@MainActor
final class TransitionalSpringboardContent {
    private struct ItemHitArea {
        let frame: CGRect
        let pageItem: LaunchpadDatabase.PageItem
    }

    private static let columnCount = 7
    private static let rowCount = 5

    private let rootLayer: CALayer
    private let size: CGSize
    private let backingScaleFactor: CGFloat
    private let firstPageItems: [LaunchpadDatabase.PageItem]
    private let allApplications: [LaunchpadDatabase.PageItem]
    private var pageLayer: CALayer?
    private var searchText = ""
    private var itemHitAreas: [ItemHitArea] = []

    var itemCount: Int { firstPageItems.count }
    var applicationCount: Int { allApplications.count }

    init(rootLayer: CALayer, size: CGSize, backingScaleFactor: CGFloat) {
        self.rootLayer = rootLayer
        self.size = size
        self.backingScaleFactor = backingScaleFactor
        self.firstPageItems = LaunchpadDatabase.firstPageItems()
        self.allApplications = LaunchpadDatabase.allApplications()
        render()
    }

    func removeFromRootLayer() {
        pageLayer?.removeFromSuperlayer()
        pageLayer = nil
        itemHitAreas = []
    }

    func handleKeyDown(keyCode: Int64, characters: String, hasCommandModifier: Bool) -> SpringboardContentAction {
        switch keyCode {
        case SpringboardKeyCode.escape:
            guard !searchText.isEmpty else { return .dismiss(reason: "escape") }
            searchText = ""
            render()
        case SpringboardKeyCode.delete:
            guard !searchText.isEmpty else { return .none }
            searchText.removeLast()
            render()
        case SpringboardKeyCode.returnKey, SpringboardKeyCode.keypadEnter:
            if let firstApplication = visibleItems.first(where: { $0.kind == .application }) {
                return launchAction(for: firstApplication)
            }
        default:
            guard
                !hasCommandModifier,
                !characters.isEmpty,
                !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return .none }
            searchText += characters
            render()
        }
        return .none
    }

    func handleClick(atWindowPoint windowPoint: CGPoint) -> SpringboardContentAction {
        guard let hitArea = itemHitAreas.first(where: { $0.frame.contains(windowPoint) }) else {
            return .dismiss(reason: "clicked outside the icons")
        }
        switch hitArea.pageItem.kind {
        case .application:
            return launchAction(for: hitArea.pageItem)
        case .folder:
            return .none
        }
    }

    private func launchAction(for pageItem: LaunchpadDatabase.PageItem) -> SpringboardContentAction {
        guard let bundleIdentifier = pageItem.bundleIdentifier else { return .none }
        return .launch(bundleIdentifier: bundleIdentifier, title: pageItem.title)
    }

    // MARK: - Drawing

    /// The first page, or the applications matching the search text.
    private var visibleItems: [LaunchpadDatabase.PageItem] {
        let maximumItemCount = Self.columnCount * Self.rowCount
        guard !searchText.isEmpty else { return Array(firstPageItems.prefix(maximumItemCount)) }
        return Array(
            allApplications
                .filter { $0.title.localizedCaseInsensitiveContains(searchText) }
                .prefix(maximumItemCount)
        )
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer?.removeFromSuperlayer()
        let newPageLayer = makePageLayer()
        // Lay the page out top-down whatever the window's root layer does.
        newPageLayer.isGeometryFlipped = !rootLayer.contentsAreFlipped()
        rootLayer.addSublayer(newPageLayer)
        pageLayer = newPageLayer
        CATransaction.commit()
    }

    private func makePageLayer() -> CALayer {
        let newPageLayer = CALayer()
        newPageLayer.frame = CGRect(origin: .zero, size: size)
        newPageLayer.backgroundColor = CGColor(gray: 0, alpha: 0.6)

        let searchFieldLayer = makeTextLayer(
            text: searchText.isEmpty ? "Type to search" : searchText,
            fontSize: 15,
            opacity: searchText.isEmpty ? 0.5 : 1
        )
        searchFieldLayer.frame = CGRect(x: size.width / 2 - 120, y: size.height * 0.06, width: 240, height: 22)
        newPageLayer.addSublayer(searchFieldLayer)

        let horizontalMargin = size.width * 0.12
        let topMargin = size.height * 0.14
        let cellWidth = (size.width - horizontalMargin * 2) / CGFloat(Self.columnCount)
        let cellHeight = size.height * 0.72 / CGFloat(Self.rowCount)
        let iconSide = min(cellWidth, cellHeight) * 0.62

        var newItemHitAreas: [ItemHitArea] = []
        for (itemIndex, pageItem) in visibleItems.enumerated() {
            let cellOrigin = CGPoint(
                x: horizontalMargin + CGFloat(itemIndex % Self.columnCount) * cellWidth,
                y: topMargin + CGFloat(itemIndex / Self.columnCount) * cellHeight
            )
            let iconFrame = CGRect(x: cellOrigin.x + (cellWidth - iconSide) / 2, y: cellOrigin.y, width: iconSide, height: iconSide)
            let titleFrame = CGRect(x: cellOrigin.x, y: iconFrame.maxY + 8, width: cellWidth, height: 18)

            let iconLayer = CALayer()
            iconLayer.frame = iconFrame
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.contentsScale = backingScaleFactor
            if let iconImage = pageItem.iconPNGData.flatMap(Self.makeImage(fromPNGData:)) {
                iconLayer.contents = iconImage
            } else {
                iconLayer.backgroundColor = CGColor(gray: 1, alpha: pageItem.kind == .folder ? 0.25 : 0.12)
                iconLayer.cornerRadius = iconSide * 0.22
            }
            newPageLayer.addSublayer(iconLayer)

            let titleLayer = makeTextLayer(text: pageItem.title, fontSize: 13, opacity: 1)
            titleLayer.frame = titleFrame
            newPageLayer.addSublayer(titleLayer)

            newItemHitAreas.append(ItemHitArea(frame: iconFrame.union(titleFrame), pageItem: pageItem))
        }
        itemHitAreas = newItemHitAreas
        return newPageLayer
    }

    private func makeTextLayer(text: String, fontSize: CGFloat, opacity: Float) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.font = CTFontCreateUIFontForLanguage(.label, fontSize, nil)
        textLayer.fontSize = fontSize
        textLayer.foregroundColor = CGColor(gray: 1, alpha: 1)
        textLayer.opacity = opacity
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .end
        textLayer.contentsScale = backingScaleFactor
        return textLayer
    }

    private static func makeImage(fromPNGData pngData: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(pngData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }
}
