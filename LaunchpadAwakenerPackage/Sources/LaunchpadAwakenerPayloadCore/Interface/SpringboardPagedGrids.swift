import CoreGraphics
import Foundation
import QuartzCore

/// Horizontally paged grids with their page dots; macOS 15's `ECPagerLayer` with its `ECPagerControlLayer`.
///
/// The main springboard and an open folder each have one, and page the same way: following a drag or a
/// trackpad scroll, settling by 15's velocity rule, rubber-banding at the ends.
@MainActor
final class SpringboardPagedGrids {
    let scrollLayer = CAScrollLayer()
    let pagerControlLayer = SpringboardPagerControlLayer()

    private let metrics: SpringboardMetrics
    private let scale: CGFloat
    /// One page's frame inside the scroll layer.
    private let pageFrame: (Int) -> CGRect
    /// The scroll distance from one page to the next: the width of the paged layer.
    private let pageStride: CGFloat

    private(set) var pageGrids: [SpringboardPageGrid] = []
    private(set) var currentPageIndex = 0
    private(set) var scrollValue: CGFloat = 0

    /// A trackpad scroll in progress: where it started and when.
    private var trackpadScroll: (startScrollValue: CGFloat, startTimestamp: UInt64)?
    /// A notched-wheel scroll waiting to settle: where it started.
    private var wheelScrollStartValue: CGFloat?
    private var wheelSettleTask: Task<Void, Never>?

    /// Called whenever the current page changes, after the change.
    var currentPageDidChange: (() -> Void)?

    /// Whether these pages are in jiggle mode, every icon shaking, as macOS 15's `-[ECSBPager setDeleting:]`
    /// put a pager's own pages (15.5 `0x10002DBD0`). Pages built later shake as well.
    var isJiggling = false {
        didSet {
            guard isJiggling != oldValue else { return }
            applyJiggling(to: itemLayers)
        }
    }

    /// Called for each icon about to jiggle, so the owner can tell it whether it has a close box.
    var itemLayerWillJiggle: ((SpringboardItemLayer) -> Void)?

    private func applyJiggling(to itemLayers: [SpringboardItemLayer]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for itemLayer in itemLayers {
            if isJiggling {
                itemLayerWillJiggle?(itemLayer)
            }
            itemLayer.isJiggling = isJiggling
        }
        CATransaction.commit()
    }

    init(metrics: SpringboardMetrics, scale: CGFloat, pageStride: CGFloat, pageFrame: @escaping (Int) -> CGRect) {
        self.metrics = metrics
        self.scale = scale
        self.pageStride = pageStride
        self.pageFrame = pageFrame
        scrollLayer.scrollMode = .horizontally
        scrollLayer.masksToBounds = false
    }

    func tearDown() {
        wheelSettleTask?.cancel()
    }

    var itemLayers: [SpringboardItemLayer] {
        pageGrids.flatMap(\.itemLayers)
    }

    var currentPageGrid: SpringboardPageGrid? {
        pageGrids.indices.contains(currentPageIndex) ? pageGrids[currentPageIndex] : nil
    }

    // MARK: - Pages

    /// Replaces every page. `centeredRowOffset` moves a page's grid right, for a single short row.
    func showPages(
        _ itemsByPage: [[LaunchpadItem]],
        rowCount: Int,
        pageIndex: Int,
        centeredRowOffset: (Int) -> CGFloat = { _ in 0 },
        itemLayerWasFilled: @escaping (SpringboardItemLayer) -> Void
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageGrids.forEach { $0.gridLayer.removeFromSuperlayer() }
        pageGrids = itemsByPage.compactMap { pageItems in
            SpringboardPageGrid(items: pageItems, metrics: metrics, rowCount: rowCount, scale: scale, itemLayerWasFilled: itemLayerWasFilled)
        }
        for (gridIndex, pageGrid) in pageGrids.enumerated() {
            scrollLayer.addSublayer(pageGrid.gridLayer)
            pageGrid.layout(in: pageFrame(gridIndex), centeredRowOffset: centeredRowOffset(pageGrid.items.count))
        }
        currentPageIndex = min(max(pageIndex, 0), max(pageGrids.count - 1, 0))
        pagerControlLayer.configure(pageCount: pageGrids.count, currentPageIndex: currentPageIndex, metrics: metrics)
        CATransaction.commit()
        if isJiggling {
            applyJiggling(to: itemLayers)
        }
        setScrollValue(pageStride * CGFloat(currentPageIndex), animated: false)
    }

    /// Adds an empty page after the last, for an icon dragged past it.
    func appendEmptyPage(rowCount: Int, itemLayerWasFilled: @escaping (SpringboardItemLayer) -> Void) {
        guard let emptyGrid = SpringboardPageGrid(items: [], metrics: metrics, rowCount: rowCount, scale: scale, itemLayerWasFilled: itemLayerWasFilled) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageGrids.append(emptyGrid)
        scrollLayer.addSublayer(emptyGrid.gridLayer)
        emptyGrid.layout(in: pageFrame(pageGrids.count - 1), centeredRowOffset: 0)
        pagerControlLayer.configure(pageCount: pageGrids.count, currentPageIndex: currentPageIndex, metrics: metrics)
        CATransaction.commit()
    }

    // MARK: - Scrolling

    func setScrollValue(_ newScrollValue: CGFloat, animated: Bool) {
        scrollValue = newScrollValue
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(SpringboardPreferences.pageAnimationDuration)
            let controlPoints = SpringboardPaging.pageAnimationControlPoints
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: controlPoints.0, controlPoints.1, controlPoints.2, controlPoints.3))
        } else {
            CATransaction.setDisableActions(true)
        }
        let displayedScrollValue = SpringboardPaging.rubberBandedScrollValue(newScrollValue, pageWidth: pageStride, pageCount: pageGrids.count)
        scrollLayer.scroll(to: CGPoint(x: displayedScrollValue, y: 0))
        pagerControlLayer.setCurrentPageIndex(currentPageIndex)
        CATransaction.commit()
    }

    func turn(toPageAt pageIndex: Int) {
        guard !pageGrids.isEmpty else { return }
        let previousPageIndex = currentPageIndex
        currentPageIndex = min(max(pageIndex, 0), pageGrids.count - 1)
        setScrollValue(pageStride * CGFloat(currentPageIndex), animated: true)
        if currentPageIndex != previousPageIndex {
            currentPageDidChange?()
        }
    }

    func follow(scrollValue newScrollValue: CGFloat) {
        setScrollValue(newScrollValue, animated: false)
    }

    /// Settles a released drag that started at `startScrollValue` at `startTimestamp`.
    func settleDrag(startScrollValue: CGFloat, startTimestamp: UInt64, endTimestamp: UInt64) {
        turn(toPageAt: SpringboardPaging.settledPageIndex(
            currentPageIndex: currentPageIndex,
            pageCount: pageGrids.count,
            startScrollValue: startScrollValue,
            endScrollValue: scrollValue,
            elapsedNanoseconds: endTimestamp > startTimestamp ? endTimestamp - startTimestamp : 0
        ))
    }

    /// Follows a trackpad or wheel scroll as 15 did; momentum is ignored, so content stops when the
    /// fingers lift.
    func handleScrollWheel(_ scrollWheel: SpringboardInputEvent.ScrollWheel, timestamp: UInt64) {
        guard scrollWheel.momentumPhase == 0, !pageGrids.isEmpty else { return }
        let distance = SpringboardPaging.scrollDistance(
            horizontalLineDelta: scrollWheel.horizontalLineDelta,
            verticalLineDelta: scrollWheel.verticalLineDelta,
            reversesScrollGesture: SpringboardPreferences.reversesScrollGesture
        )

        let phaseBegan: Int64 = 1
        let phaseEnded: Int64 = 4
        let phaseCancelled: Int64 = 8
        if scrollWheel.isContinuous, scrollWheel.scrollPhase != 0 {
            switch scrollWheel.scrollPhase {
            case phaseBegan:
                trackpadScroll = (scrollValue, timestamp)
                follow(scrollValue: scrollValue + distance)
            case phaseEnded, phaseCancelled:
                guard let trackpadScroll else { return }
                self.trackpadScroll = nil
                settleDrag(startScrollValue: trackpadScroll.startScrollValue, startTimestamp: trackpadScroll.startTimestamp, endTimestamp: timestamp)
            default:
                guard trackpadScroll != nil else { return }
                follow(scrollValue: scrollValue + distance)
            }
            return
        }

        // A notched wheel: follow, and settle on one page once the wheel pauses.
        guard distance != 0 else { return }
        if wheelScrollStartValue == nil {
            wheelScrollStartValue = scrollValue
        }
        follow(scrollValue: scrollValue + distance)
        wheelSettleTask?.cancel()
        wheelSettleTask = Task { [weak self] in
            try? await Task.sleep(for: SpringboardPaging.wheelSettleDelay)
            guard !Task.isCancelled, let self, let startScrollValue = self.wheelScrollStartValue else { return }
            self.wheelScrollStartValue = nil
            self.turn(toPageAt: SpringboardPaging.wheelSettledPageIndex(
                currentPageIndex: self.currentPageIndex,
                pageCount: self.pageGrids.count,
                startScrollValue: startScrollValue,
                endScrollValue: self.scrollValue
            ))
        }
    }

    func cancelPendingWheelSettle() {
        wheelSettleTask?.cancel()
        wheelScrollStartValue = nil
    }

    // MARK: - Hit testing

    /// The current page's grid and `point` — in the scroll layer's superlayer — in that grid.
    func pointInCurrentGrid(_ point: CGPoint) -> (SpringboardPageGrid, CGPoint)? {
        guard let currentPageGrid, let superlayer = scrollLayer.superlayer else { return nil }
        return (currentPageGrid, superlayer.convert(point, to: currentPageGrid.gridLayer))
    }

    /// The page whose dot is under `point`, a point in the dots' superlayer.
    func pageIndexOfIndicator(at point: CGPoint) -> Int? {
        guard let superlayer = pagerControlLayer.superlayer else { return nil }
        return pagerControlLayer.pageIndex(at: superlayer.convert(point, to: pagerControlLayer))
    }
}
