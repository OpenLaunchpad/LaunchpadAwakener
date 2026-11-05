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
