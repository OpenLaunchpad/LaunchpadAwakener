import CoreGraphics
import Foundation

/// The geometry of an open folder, computed the way macOS 15.5's Launchpad computed it.
///
/// The panel spans almost the whole width, sits centred in the springboard whatever folder was opened,
/// and uses the main grid's cells (`-[ECSBPager showGroupForItemLayer:onPage:selectingFirstItem:]`,
/// 15.5 `0x100057AEC`, and `-[ECSBGroupLayer layout]`, `0x10004C734`). The folder layer shares the
/// springboard layer's coordinate space; everything else is inside the folder layer, origin at the
/// bottom left, y up.
package struct SpringboardFolderMetrics: Sendable, Equatable {
    package static let panelCornerRadius: CGFloat = 36
    package static let titleFontSize: CGFloat = 28
    /// The title stays clickable this far to either side of its text (`labelEditLayer`).
    package static let titleEditingOutset: CGFloat = 200

    package let rowCount: Int
    package let columnCount: Int
    /// The folder layer, in the springboard layer's superlayer.
    package let folderFrame: CGRect
    package let scrollFrame: CGRect
    package let pageSize: CGSize
    /// The frosted rounded rectangle.
    package let panelFrame: CGRect
    package let pagerControlFrame: CGRect
    package let leftMargin: CGFloat
    package let rightMargin: CGFloat

    /// - Parameters:
    ///   - applicationCount: Applications on all of the folder's pages.
    ///   - isDragging: While an icon is being dragged, a full last row gets an empty row below it.
    package init(metrics: SpringboardMetrics, applicationCount: Int, isDragging: Bool) {
        let mainRowCount = metrics.input.rowCount
        let columnCount = metrics.input.columnCount
        var rowCount = max(min(Int((Double(applicationCount) / Double(columnCount)).rounded(.up)), mainRowCount), 1)
        if isDragging, applicationCount % columnCount == 0, rowCount < mainRowCount - 1 {
            rowCount += 1
        }
        self.rowCount = rowCount
        self.columnCount = columnCount

        let topMargin = metrics.topMargin
        let bottomMargin = metrics.bottomMargin
        leftMargin = max(metrics.leftMargin, 90)
        rightMargin = max(metrics.rightMargin, 90)

        let springboardFrame = metrics.springboardFrame
        var folderHeight = CGFloat(rowCount) * metrics.cellSize.height + bottomMargin + topMargin + 30
        let notchHeight = rowCount >= 5 ? metrics.input.notchHeight : 0
        var folderY = springboardFrame.minY + CGFloat(Int((springboardFrame.height - folderHeight - notchHeight) * 0.5))
        if folderY > 30 {
            folderY -= 30
            folderHeight += 30
        }
        folderFrame = CGRect(x: springboardFrame.minX, y: folderY, width: springboardFrame.width, height: folderHeight)

        let folderWidth = folderFrame.width
        scrollFrame = CGRect(x: 0, y: bottomMargin - 10, width: folderWidth, height: folderHeight - 30)
        pageSize = CGSize(
            width: folderWidth - leftMargin - rightMargin,
            height: (folderHeight - 30) - (topMargin + 40 + (bottomMargin - 10))
        )
        panelFrame = CGRect(
            x: leftMargin - 20,
            y: 0,
            width: folderWidth - leftMargin - rightMargin + 40,
            height: folderHeight - 30 - topMargin
        )
        pagerControlFrame = CGRect(x: 0, y: max(floor(bottomMargin * 0.5 - 7.5), 0), width: folderWidth, height: SpringboardMetrics.pagerControlHeight)
    }

    package func pageFrame(at pageIndex: Int) -> CGRect {
        CGRect(x: leftMargin + CGFloat(pageIndex) * folderFrame.width, y: 0, width: pageSize.width, height: pageSize.height)
    }

    package func scrollValue(forPageAt pageIndex: Int) -> CGFloat {
        folderFrame.width * CGFloat(pageIndex)
    }

    /// The title, centred over the pages in the band above the panel.
    package func titleFrame(forTitleSize titleSize: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(Int(leftMargin + pageSize.width / 2 - titleSize.width / 2)),
            y: CGFloat(Int(panelFrame.height + (folderFrame.height - panelFrame.height - titleSize.height) / 2)),
            width: CGFloat(Int(titleSize.width)),
            height: CGFloat(Int(titleSize.height))
        )
    }

    /// The folder icon's frosted square: the icon inset by 5, 7, 10 or 12 points by size
    /// (`-[ECSBItemLayer _backdropInsetForFrame:]`, `0x1000622D8`).
    package static func folderBackdropInset(forIconSide iconSide: CGFloat) -> CGFloat {
        switch iconSide {
        case ...60: 5
        case ...80: 7
        case ..<128: 10
        default: 12
        }
    }

    /// How far the thumbnail grid sits inside the folder icon's square: a tenth of its width, truncated.
    package static func thumbnailGridInset(forBackdropSide backdropSide: CGFloat) -> CGFloat {
        CGFloat(Int(backdropSide * 0.1))
    }
}
