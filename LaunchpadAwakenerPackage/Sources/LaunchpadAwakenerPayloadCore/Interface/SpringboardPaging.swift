import CoreGraphics
import Foundation

/// macOS 15.5's rules for following a scroll or a drag and deciding where it settles.
///
/// Scroll values are in points, page `i` at `pageWidth × i` (`-[ECPagerLayer scrollValue]`).
package enum SpringboardPaging {
    /// Beyond the first and last page the content follows at a quarter of the movement
    /// (`-[ECSBLayer setScrollValue:]`, 15.5 `0x10001EA70`).
    package static let rubberBandFactor: CGFloat = 0.25

    /// Below this, a released drag or trackpad scroll springs back (`-[ECSBLayer gesture:]`,
    /// `0x1000822F0`): about 200 points per second, averaged over the whole gesture.
    package static let pageChangeVelocityThreshold: Double = 2.0

    /// A drag starts once the pointer has moved this far (`-[ECPagerLayer leftMouseDragged:]`).
    package static let dragThreshold: CGFloat = 3

    /// After the last notched-wheel event, this long without another settles the scroll
    /// (`sub_10008296C`); 375 ms with Shift held.
    package static let wheelSettleDelay: Duration = .milliseconds(75)

    /// The page-change animation (`-[ECPagerLayer scrollToPageIndex:]`, `0x1000B7348`): the
    /// `springboard-page-duration` preference, 0.5 s unless set, on this curve.
    package static let pageAnimationControlPoints: (Float, Float, Float, Float) = (0, 0, 0.35841, 1.0019)

    package static func rubberBandedScrollValue(_ scrollValue: CGFloat, pageWidth: CGFloat, pageCount: Int) -> CGFloat {
        let maximumScrollValue = pageWidth * CGFloat(max(pageCount - 1, 0))
        if scrollValue < 0 {
            return scrollValue * rubberBandFactor
        }
        if scrollValue > maximumScrollValue {
            return maximumScrollValue + (scrollValue - maximumScrollValue) * rubberBandFactor
        }
        return scrollValue
    }

    /// How far one scroll event moves the content: twice the larger of the two line deltas — vertical
    /// scrolling pages too — reversed unless `springboard-reverse-scroll-gesture` is off.
    package static func scrollDistance(horizontalLineDelta: Double, verticalLineDelta: Double, reversesScrollGesture: Bool) -> CGFloat {
        let delta = abs(horizontalLineDelta) > abs(verticalLineDelta) ? horizontalLineDelta : verticalLineDelta
        let distance = CGFloat(2 * delta)
        return reversesScrollGesture ? -distance : distance
    }

    /// Where a released trackpad scroll or drag settles: back on `currentPageIndex` unless it moved
    /// fast enough, otherwise one page in the direction it moved.
    package static func settledPageIndex(
        currentPageIndex: Int,
        pageCount: Int,
        startScrollValue: CGFloat,
        endScrollValue: CGFloat,
        elapsedNanoseconds: UInt64
    ) -> Int {
        guard pageCount > 0 else { return 0 }
        guard elapsedNanoseconds > 0 else { return currentPageIndex }
        let velocity = Double(abs(endScrollValue - startScrollValue)) / Double(elapsedNanoseconds) * 10_000_000
        guard velocity > pageChangeVelocityThreshold else { return currentPageIndex }
        return pageIndex(afterMovingFrom: startScrollValue, to: endScrollValue, currentPageIndex: currentPageIndex, pageCount: pageCount)
    }

    /// Where a notched-wheel scroll settles once it pauses: any net movement turns one page.
    package static func wheelSettledPageIndex(
        currentPageIndex: Int,
        pageCount: Int,
        startScrollValue: CGFloat,
        endScrollValue: CGFloat
    ) -> Int {
        guard pageCount > 0 else { return 0 }
        guard endScrollValue != startScrollValue else { return currentPageIndex }
        return pageIndex(afterMovingFrom: startScrollValue, to: endScrollValue, currentPageIndex: currentPageIndex, pageCount: pageCount)
    }

    private static func pageIndex(afterMovingFrom startScrollValue: CGFloat, to endScrollValue: CGFloat, currentPageIndex: Int, pageCount: Int) -> Int {
        if endScrollValue < 0 {
            return 0
        }
        let targetPageIndex = endScrollValue > startScrollValue ? currentPageIndex + 1 : currentPageIndex - 1
        return min(max(targetPageIndex, 0), pageCount - 1)
    }
}

/// Arrow keys over a page's grid, as `-[ECSBPage navigate:withEvent:]` (15.5 `0x100051660`) moves
/// the selection: never off the page — Command-arrows turn pages.
package enum SpringboardNavigation {
    package enum Direction: Sendable, Equatable {
        case up
        case down
        case left
        case right
    }

    package static func selectedIndex(after direction: Direction, from currentIndex: Int?, itemCount: Int, columnCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        guard let currentIndex, currentIndex < itemCount else {
            return direction == .down || direction == .right ? 0 : itemCount - 1
        }
        let candidateIndex = switch direction {
        case .left: currentIndex - 1
        case .right: currentIndex + 1
        case .up: currentIndex - columnCount
        case .down: currentIndex + columnCount
        }
        return (0..<itemCount).contains(candidateIndex) ? candidateIndex : currentIndex
    }
}

/// Where a dragged icon lands, by macOS 15.5's rules.
package enum SpringboardDragging {
    /// Faster than this the dragged icon makes nothing move yet (`-[ECSBDragCapture leftMouseDragged:in:]`,
    /// 15.5 `0x1000B6058`): about 75 points per second.
    package static let settlingSpeedThreshold: Double = 0.75
    /// How long the dragged icon must slow down or rest before anything responds.
    package static let settlingDelay: Duration = .milliseconds(150)
    /// How long the other icons take to make room.
    package static let makeRoomDuration: CFTimeInterval = 0.4
    /// Holding over an edge turns the page after this long, then again at the repeat interval.
    package static let edgePageTurnDelay: Duration = .milliseconds(700)
    package static let edgePageTurnRepeatInterval: Duration = .milliseconds(750)
    /// Holding over a folder this long opens it (`OpenGroupDragState_hoverTimerFired_1s`).
    package static let springLoadingDelay: Duration = .seconds(1)

    /// The speed 15 compared with ``settlingSpeedThreshold``: points per nanosecond, times 10⁷.
    package static func speed(from previousLocation: CGPoint, to location: CGPoint, elapsedNanoseconds: UInt64) -> Double {
        guard elapsedNanoseconds > 0 else { return .infinity }
        return Double(hypot(location.x - previousLocation.x, location.y - previousLocation.y)) / Double(elapsedNanoseconds) * 10_000_000
    }

    /// The cell under `point` — measured from the grid's top-left corner — as
    /// `-[ECSBGridLayer itemIndexWithFrame:relativeToItemIndex:usingHysteresis:]` (`0x10011E8AC`) found it.
    ///
    /// With hysteresis the current cell keeps the item until the point leaves a zone reaching half a cell
    /// beyond it on every side. Past the last item the answer is the last cell, so no gap is left.
    package static func itemIndex(
        at point: CGPoint,
        cellSize: CGSize,
        columnCount: Int,
        itemCount: Int,
        currentIndex: Int?,
        usesHysteresis: Bool
    ) -> Int {
        guard itemCount > 0, cellSize.width > 0, cellSize.height > 0 else { return 0 }
        let column = min(max(Int(floor(point.x / cellSize.width)), 0), columnCount - 1)
        let row = max(Int(floor(point.y / cellSize.height)), 0)
        var index = column + columnCount * row
        if usesHysteresis, let currentIndex, index != currentIndex {
            let currentRow = currentIndex / columnCount
            let currentColumn = currentIndex % columnCount
            let keepZone = CGRect(
                x: CGFloat(currentColumn) * cellSize.width,
                y: CGFloat(currentRow) * cellSize.height,
                width: cellSize.width,
                height: cellSize.height
            ).insetBy(dx: -ceil(cellSize.width / 2), dy: -ceil(cellSize.height / 2))
            if keepZone.contains(point) {
                index = currentIndex
            }
        }
        return min(index, itemCount - 1)
    }
}
