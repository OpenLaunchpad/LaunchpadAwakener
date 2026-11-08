import CoreGraphics
import Foundation

/// Where the Dock sits, as the `orientation` preference of `com.apple.dock` says.
package enum DockOrientation: String, Sendable, Equatable {
    case bottom
    case left
    case right
}

/// The geometry of the springboard, computed the way macOS 15.5's Launchpad computed it.
///
/// All frames use the layer convention of the Dock's windows: origin at the bottom left, y up.
/// Formulas and constants are those of `-[Springboard layout]` (15.5 `0x10000B10C`),
/// `-[ECSBLayer layout]` (`0x10001C1A8`), `-[ECSBGridLayer _layoutItemLayers]` (`0x10001F338`),
/// `-[ECSBItemLayer layout]` (`0x100020A14`) and `-[ECPagerControlLayer layout]` (`0x10001CDCC`).
package struct SpringboardMetrics: Sendable, Equatable {
    package struct Input: Sendable, Equatable {
        package var screenSize: CGSize
        package var dockOrientation: DockOrientation
        /// The room left for the Dock, as macOS 15 worked it out from the Dock's tiles; see
        /// ``SpringboardMetrics/dockThickness(desiredTileSize:tileSize:)``.
        package var dockThickness: CGFloat
        /// Height of the camera housing at the top of the screen; zero without one.
        package var notchHeight: CGFloat
        package var rowCount: Int
        package var columnCount: Int
        /// `springboard-zoom-style`: whether the vertical margins grow on wide screens too.
        package var zoomStyle: Int
        /// `ceil(ascent + descent + leading)` of the label font.
        package var labelLineHeight: CGFloat

        package init(
            screenSize: CGSize,
            dockOrientation: DockOrientation,
            dockThickness: CGFloat,
            notchHeight: CGFloat,
            rowCount: Int,
            columnCount: Int,
            zoomStyle: Int,
            labelLineHeight: CGFloat
        ) {
            self.screenSize = screenSize
            self.dockOrientation = dockOrientation
            self.dockThickness = dockThickness
            self.notchHeight = notchHeight
            self.rowCount = rowCount
            self.columnCount = columnCount
            self.zoomStyle = zoomStyle
            self.labelLineHeight = labelLineHeight
        }
    }

    /// Gap kept between the springboard and both the Dock and the top of the screen.
    package static let edgeGap: CGFloat = 30
    package static let searchFieldSize = CGSize(width: 250, height: 25)
    package static let pagerControlHeight: CGFloat = 15
    package static let pagerIndicatorSide: CGFloat = 15
    package static let pagerIndicatorSpacing: CGFloat = 5
    package static let pagerDotSide: CGFloat = 8

    package let input: Input
    /// The springboard layer (15's `ECSBLayer`) in the window.
    package let springboardFrame: CGRect
    package let zoomFactor: CGFloat
    package let leftMargin: CGFloat
    package let rightMargin: CGFloat
    package let topMargin: CGFloat
    package let bottomMargin: CGFloat
    /// The margin below the grid before widening, which places the page dots.
    package let unadjustedBottomMargin: CGFloat
    /// The horizontally scrolling layer holding every page, in the springboard layer.
    package let scrollFrame: CGRect
    package let pageSize: CGSize
    package let cellSize: CGSize
    package let iconSide: CGFloat
    package let labelHeight: CGFloat
    package let labelMaximumWidth: CGFloat
    /// Space below each label inside its cell.
    package let cellBottomPadding: CGFloat
    /// In the springboard layer.
    package let searchFieldFrame: CGRect
    /// The strip the page dots sit in, in the springboard layer.
    package let pagerControlFrame: CGRect

    package init(_ input: Input) {
        self.input = input
        let screenWidth = input.screenSize.width
        let screenHeight = input.screenSize.height
        let rowCount = CGFloat(input.rowCount)
        let columnCount = CGFloat(input.columnCount)

        let gridWidth: CGFloat
        switch input.dockOrientation {
        case .bottom:
            springboardFrame = CGRect(
                x: 0,
                y: input.dockThickness + Self.edgeGap,
                width: screenWidth,
                height: screenHeight - (input.dockThickness + Self.edgeGap)
            )
            gridWidth = screenWidth
        case .left, .right:
            springboardFrame = CGRect(x: 0, y: Self.edgeGap, width: screenWidth, height: screenHeight - Self.edgeGap)
            gridWidth = screenWidth - input.dockThickness
        }
        let layerWidth = springboardFrame.width
        let layerHeight = springboardFrame.height

        let columnUnit = floor(gridWidth / (2 * columnCount + 1))
        let verticalSlack = floor(layerHeight - (columnUnit + 40) * rowCount)
        let sideMargin = max(floor(columnUnit * 0.5), 90)
        let baseTopMargin = max(floor(verticalSlack * 0.15), 35)
        let baseBottomMargin = max(floor(verticalSlack * 0.25), 35)
        let baseLeftMargin = sideMargin + (input.dockOrientation == .left ? input.dockThickness : 0)
        let baseRightMargin = sideMargin + (input.dockOrientation == .right ? input.dockThickness : 0)

        var zoomFactor: CGFloat = switch screenWidth {
        case let width where width > 1920: 0.6
        case let width where width > 1680: 0.3
        case let width where width > 1440: 0.2
        default: 0
        }
        if zoomFactor > 0.1, input.dockOrientation != .bottom {
            zoomFactor -= 0.1
        }
        self.zoomFactor = zoomFactor

        leftMargin = floor(baseLeftMargin + layerWidth * 0.2 * zoomFactor)
        rightMargin = floor(baseRightMargin + layerWidth * 0.2 * zoomFactor)
        topMargin = input.zoomStyle == 0 || input.zoomStyle == 2
            ? baseTopMargin
            : floor(baseTopMargin + layerHeight * 0.2 * zoomFactor)
        bottomMargin = input.zoomStyle == 1 || input.zoomStyle == 2
            ? floor(baseBottomMargin + (layerHeight - Self.edgeGap) * 0.2 * zoomFactor)
            : baseBottomMargin
        unadjustedBottomMargin = baseBottomMargin

        scrollFrame = CGRect(x: 0, y: bottomMargin, width: layerWidth, height: layerHeight - Self.edgeGap - bottomMargin)
        pageSize = CGSize(
            width: layerWidth - leftMargin - rightMargin,
            height: layerHeight - Self.edgeGap - (input.notchHeight + topMargin + bottomMargin)
        )
        cellSize = CGSize(
            width: CGFloat(Int(pageSize.width / columnCount)),
            height: CGFloat(Int(pageSize.height / rowCount))
        )

        labelHeight = input.labelLineHeight + 7
        cellBottomPadding = min(ceil(cellSize.height * 0.125), 20)
        iconSide = Self.snappedIconSide(min(cellSize.width, cellSize.height) - (labelHeight + 24))
        labelMaximumWidth = cellSize.width - 12

        searchFieldFrame = CGRect(
            x: layerWidth / 2 - Self.searchFieldSize.width / 2,
            y: layerHeight - (topMargin + input.notchHeight + 15),
            width: Self.searchFieldSize.width,
            height: Self.searchFieldSize.height
        )
        pagerControlFrame = CGRect(
            x: 0,
            y: max(floor(baseBottomMargin * 0.5 - Self.pagerControlHeight / 2), 0),
            width: layerWidth,
            height: Self.pagerControlHeight
        )
    }

    /// Page `pageIndex` inside the scrolling layer; pages sit one springboard width apart.
    package func pageFrame(at pageIndex: Int) -> CGRect {
        CGRect(
            x: leftMargin + CGFloat(pageIndex) * springboardFrame.width,
            y: 0,
            width: pageSize.width,
            height: pageSize.height
        )
    }

    /// The scroll position that shows page `pageIndex`.
    package func scrollValue(forPageAt pageIndex: Int) -> CGFloat {
        springboardFrame.width * CGFloat(pageIndex)
    }

    /// The cell of item `itemIndex` on a page, in the page; the first row is at the top.
    package func cellFrame(at itemIndex: Int) -> CGRect {
        let row = itemIndex / input.columnCount
        let column = itemIndex % input.columnCount
        return CGRect(
            x: CGFloat(column) * cellSize.width,
            y: pageSize.height - CGFloat(row + 1) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
    }

    /// How far a search page with fewer results than columns moves right to centre its one row.
    package func centeredRowOffset(forItemCount itemCount: Int) -> CGFloat {
        guard itemCount > 0, itemCount < input.columnCount else { return 0 }
        let offset = ((pageSize.width - cellSize.width * CGFloat(itemCount)) / 2).rounded()
        return itemCount % 2 == 1 ? offset - 1 : offset
    }

    /// Indicator `indicatorIndex` of `pageCount`, in the pager control strip.
    package func pagerIndicatorFrame(at indicatorIndex: Int, pageCount: Int) -> CGRect {
        let totalWidth = CGFloat(pageCount) * Self.pagerIndicatorSide + CGFloat(max(pageCount - 1, 0)) * Self.pagerIndicatorSpacing
        let firstX = CGFloat(Int(springboardFrame.width / 2 - totalWidth / 2))
        return CGRect(
            x: firstX + CGFloat(indicatorIndex) * (Self.pagerIndicatorSide + Self.pagerIndicatorSpacing),
            y: 0,
            width: Self.pagerIndicatorSide,
            height: Self.pagerIndicatorSide
        )
    }

    /// The dot inside an indicator: 8 points, inset `Int((15 − 8) / 2)` from the indicator's corner.
    package func pagerDotFrame(inIndicatorFrame indicatorFrame: CGRect) -> CGRect {
        let inset = CGFloat(Int((Self.pagerIndicatorSide - Self.pagerDotSide) / 2))
        return CGRect(x: indicatorFrame.minX + inset, y: indicatorFrame.minY + inset, width: Self.pagerDotSide, height: Self.pagerDotSide)
    }

    /// The room macOS 15.5's Launchpad left the Dock: `ceilf(tileSize + distanceTop + distanceBottom)` of the
    /// `DockBar` (`-[Springboard layout]`, 15.5 `0x10000B10C`), 79 points at the default Dock size.
    ///
    /// The Dock makes a tile `desiredTileSize` plus an inset on each side and spaces it by a table of tile
    /// sizes (15.5 `0x1000DBB44`). Only when the bar does not fit the screen does it shrink `tileSize` and
    /// look the shrunk size up again (15.5 `0x100027D84`), so the distances belong to whichever size was
    /// looked up last. 27.2's Dock sizes tiles the same way (27.2 `0x10001149C`), but its glass bar is
    /// taller: its table puts 5 or 6 points above a tile where 15.5's put 0 to 2 (27.2 `0x100078598`), and
    /// the bar is 94 points high at the default size. Leaving room for that bar made the icons a size
    /// smaller than 15's on several screens, so the room is worked out from 15.5's table instead.
    package static func dockThickness(desiredTileSize: Float, tileSize: Float) -> CGFloat {
        let desiredSpacing = DockTileSpacing(lookingUp: desiredTileSize)
        let isShrunkToFit = tileSize != desiredTileSize + desiredSpacing.tileInset * 2
        let spacing = isShrunkToFit ? DockTileSpacing(lookingUp: tileSize) : desiredSpacing
        return CGFloat((tileSize + spacing.distanceTop + spacing.distanceBottom).rounded(.up))
    }

    /// 79 points: the room left at the default Dock size, 64-point icons in 68-point tiles.
    package static let defaultDockThickness = dockThickness(desiredTileSize: 64, tileSize: 68)

    /// The inset and the distances macOS 15.5's Dock gave a tile of the size it looked up
    /// (15.5 `0x1000DBB44`).
    private struct DockTileSpacing {
        let tileInset: Float
        let distanceTop: Float
        let distanceBottom: Float

        init(lookingUp size: Float) {
            // The table gives one margin per size; the distance above a tile is that margin less both insets.
            let margin: Float
            if size > 127 {
                (tileInset, distanceBottom, margin) = (3, 10, 6)
            } else if size > 47 {
                (tileInset, distanceBottom, margin) = (2, 10, 5)
            } else if size > 31 {
                (tileInset, distanceBottom, margin) = (1, 7, 4)
            } else {
                (tileInset, distanceBottom, margin) = (1, 7, size > 23 ? 4 : 3)
            }
            distanceTop = margin - tileInset * 2
        }
    }

    /// 15's icon sizes: a multiple of 8 between 20 and 128 points.
    package static func snappedIconSide(_ rawSide: CGFloat) -> CGFloat {
        guard rawSide.isFinite else { return 20 }
        let value = UInt32(min(max(rawSide, 0), CGFloat(UInt32.max)))
        var snapped = value >= 128 ? 128 : (value & ~7)
        if Int32(bitPattern: value) < 8 {
            snapped = 1
        }
        return max(CGFloat(snapped), 20)
    }
}
