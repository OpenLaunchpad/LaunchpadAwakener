import CoreGraphics
import Foundation
import OSToolbox
import QuartzCore

/// The main interface — pages, page dots, search — and what input does to it; macOS 15's
/// `ECSBSpringboard` and `ECSBLayer`, with the behaviour of `Springboard` and `ECSBPager`.
///
/// Points handed in are in the container layer: the full screen, origin at the bottom left, y up — the
/// convention every frame in ``SpringboardMetrics`` uses.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "SpringboardInterface")
@MainActor
final class SpringboardInterface {
    enum Action {
        case none
        case dismiss(reason: String)
        /// Launch, starting the launch animation from `iconFrame` (in the container) with `iconImage`.
        case launch(LaunchpadApplication, iconFrame: CGRect, iconImage: Any?)
    }

    /// How long the typed search waits for the next key before searching (`-[ECSBLayer observeValueForKeyPath:…]`).
    private static let searchDelay: Duration = .milliseconds(150)

    let containerLayer = CALayer()
    private let layout: LaunchpadLayout
    private let metrics: SpringboardMetrics
    private let scale: CGFloat
    private let springboardLayer = CALayer()
    private let scrollLayer = CAScrollLayer()
    private let pagerControlLayer = SpringboardPagerControlLayer()
    private let searchFieldLayer = SpringboardSearchFieldLayer()
    private let noResultsLayer = SpringboardNoResultsLayer()

    private var pageGrids: [SpringboardPageGrid] = []
    private var currentPageIndex = 0
    private var scrollValue: CGFloat = 0
    private var pageIndexBeforeSearch = 0
    private var selectedItemIndex: Int?
    private var searchText = ""
    private var isShowingSearchResults = false
    private var searchTask: Task<Void, Never>?
    private var wheelSettleTask: Task<Void, Never>?

    private enum PointerTracking {
        case none
        case icon(pageIndex: Int, itemIndex: Int, itemLayer: SpringboardItemLayer, startLocation: CGPoint)
        case background(startLocation: CGPoint, startScrollValue: CGFloat, startTimestamp: UInt64, isDragging: Bool)
        case pagerIndicator(pageIndex: Int)
        case clearButton
        case searchField
    }

    private var pointerTracking: PointerTracking = .none
    /// A trackpad scroll in progress: where it started and when.
    private var trackpadScroll: (startScrollValue: CGFloat, startTimestamp: UInt64)?
    /// A notched-wheel scroll waiting to settle: where it started.
    private var wheelScrollStartValue: CGFloat?

    init(layout: LaunchpadLayout, metrics: SpringboardMetrics, scale: CGFloat, rootLayer: CALayer) {
        self.layout = layout
        self.metrics = metrics
        self.scale = scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = rootLayer.bounds
        // Keep y up inside, whatever the window's root layer does.
        containerLayer.isGeometryFlipped = rootLayer.contentsAreFlipped()
        containerLayer.backgroundColor = CGColor(gray: 0, alpha: 0.6)

        springboardLayer.frame = metrics.springboardFrame
        springboardLayer.masksToBounds = false
        scrollLayer.frame = metrics.scrollFrame
        scrollLayer.scrollMode = .horizontally
        scrollLayer.masksToBounds = false
        pagerControlLayer.frame = metrics.pagerControlFrame
        searchFieldLayer.frame = metrics.searchFieldFrame
        searchFieldLayer.configure(scale: scale)
        noResultsLayer.layout(in: metrics.pageFrame(at: 0).offsetBy(dx: metrics.scrollFrame.minX, dy: metrics.scrollFrame.minY), scale: scale)

        springboardLayer.addSublayer(noResultsLayer)
        springboardLayer.addSublayer(scrollLayer)
        springboardLayer.addSublayer(pagerControlLayer)
        springboardLayer.addSublayer(searchFieldLayer)
        containerLayer.addSublayer(springboardLayer)
        rootLayer.addSublayer(containerLayer)
        CATransaction.commit()

        showPages(layout.pages.map(\.items), isSearchResults: false, pageIndex: 0)
    }

    func tearDown() {
        searchTask?.cancel()
        wheelSettleTask?.cancel()
        containerLayer.removeFromSuperlayer()
    }

    var pageCount: Int {
        pageGrids.count
    }

    // MARK: - Pages

    private func showPages(_ itemsByPage: [[LaunchpadItem]], isSearchResults: Bool, pageIndex: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageGrids.forEach { $0.gridLayer.removeFromSuperlayer() }
        pageGrids = itemsByPage.compactMap { pageItems in
            SpringboardPageGrid(items: pageItems, metrics: metrics, scale: scale) { [weak self] itemLayer in
                self?.putIcons(in: itemLayer)
            }
        }
        if pageGrids.count != itemsByPage.count {
            #log(.error, "The Dock's grid layer refused \(itemsByPage.count - self.pageGrids.count, privacy: .public) page(s)")
        }
        for (gridIndex, pageGrid) in pageGrids.enumerated() {
            scrollLayer.addSublayer(pageGrid.gridLayer)
            let centeredRowOffset = isSearchResults ? metrics.centeredRowOffset(forItemCount: pageGrid.items.count) : 0
            pageGrid.layout(in: metrics.pageFrame(at: gridIndex), centeredRowOffset: centeredRowOffset)
        }
        isShowingSearchResults = isSearchResults
        currentPageIndex = min(max(pageIndex, 0), max(pageGrids.count - 1, 0))
        selectedItemIndex = nil
        pagerControlLayer.configure(pageCount: pageGrids.count, currentPageIndex: currentPageIndex, metrics: metrics)
        CATransaction.commit()
        setScrollValue(metrics.scrollValue(forPageAt: currentPageIndex), animated: false)
    }

    private func putIcons(in itemLayer: SpringboardItemLayer) {
        guard let item = itemLayer.item else { return }
        let iconProvider = SpringboardIconProvider.shared
        switch item {
        case .application(let application):
            itemLayer.setApplicationIcon(icon(for: application, side: metrics.iconSide), compositingFilterName: iconProvider.glassCompositingFilterName)
        case .folder(let folder):
            let thumbnailSide = (metrics.iconSide / 3).rounded()
            itemLayer.setFolderThumbnails(folder.applications.prefix(9).map { icon(for: $0, side: thumbnailSide) })
        }
    }

    private func icon(for application: LaunchpadApplication, side: CGFloat) -> CGImage? {
        if let bundleURL = application.bundleURL, let icon = SpringboardIconProvider.shared.icon(forApplicationAt: bundleURL, pointSide: side, scale: scale) {
            return icon
        }
        return SpringboardIconProvider.legacyIcon(from: application.legacyIconPNGData)
    }

    /// Puts a newly rendered icon into every item that shows it.
    func iconDidBecomeAvailable(forApplicationAt bundleURL: URL) {
        for itemLayer in pageGrids.flatMap(\.itemLayers) {
            switch itemLayer.item {
            case .application(let application) where application.bundleURL == bundleURL:
                putIcons(in: itemLayer)
            case .folder(let folder) where folder.applications.prefix(9).contains(where: { $0.bundleURL == bundleURL }):
                putIcons(in: itemLayer)
            default:
                break
            }
        }
    }

    // MARK: - Scrolling

    private var pageAnimationDuration: CFTimeInterval {
        SpringboardPreferences.pageAnimationDuration
    }

    private func setScrollValue(_ newScrollValue: CGFloat, animated: Bool) {
        scrollValue = newScrollValue
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(pageAnimationDuration)
            let controlPoints = SpringboardPaging.pageAnimationControlPoints
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: controlPoints.0, controlPoints.1, controlPoints.2, controlPoints.3))
        } else {
            CATransaction.setDisableActions(true)
        }
        let displayedScrollValue = SpringboardPaging.rubberBandedScrollValue(newScrollValue, pageWidth: metrics.springboardFrame.width, pageCount: pageGrids.count)
        scrollLayer.scroll(to: CGPoint(x: displayedScrollValue, y: 0))
        pagerControlLayer.setCurrentPageIndex(currentPageIndex)
        CATransaction.commit()
    }

    private func turn(toPageAt pageIndex: Int) {
        guard !pageGrids.isEmpty else { return }
        currentPageIndex = min(max(pageIndex, 0), pageGrids.count - 1)
        setScrollValue(metrics.scrollValue(forPageAt: currentPageIndex), animated: true)
    }

    private func follow(scrollValue newScrollValue: CGFloat) {
        setScrollValue(newScrollValue, animated: false)
    }

    // MARK: - Selection

    private func select(itemAt itemIndex: Int?) {
        currentItemLayers.enumerated().forEach { index, itemLayer in
            itemLayer.isSelected = index == itemIndex
        }
        selectedItemIndex = itemIndex
    }

    private var currentItemLayers: [SpringboardItemLayer] {
        pageGrids.indices.contains(currentPageIndex) ? pageGrids[currentPageIndex].itemLayers : []
    }

    private var currentItems: [LaunchpadItem] {
        pageGrids.indices.contains(currentPageIndex) ? pageGrids[currentPageIndex].items : []
    }

    // MARK: - Search

    private func searchTextDidChange() {
        searchFieldLayer.setText(searchText)
        searchTask?.cancel()
        guard !searchText.isEmpty else {
            clearSearchResults()
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled else { return }
            self?.showSearchResults()
        }
    }

    private func showSearchResults() {
        if !isShowingSearchResults {
            pageIndexBeforeSearch = currentPageIndex
        }
        let results = SpringboardSearch.applications(matching: searchText, in: layout) { $0.fileName }
        let itemsPerPage = metrics.input.rowCount * metrics.input.columnCount
        let resultPages = stride(from: 0, to: results.count, by: itemsPerPage).map { pageStart in
            results[pageStart..<min(pageStart + itemsPerPage, results.count)].map(LaunchpadItem.application)
        }
        showPages(resultPages, isSearchResults: true, pageIndex: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(results.isEmpty == false)
        noResultsLayer.opacity = results.isEmpty ? 1 : 0
        CATransaction.commit()
        if !results.isEmpty {
            select(itemAt: 0)
        }
    }

    private func clearSearchResults() {
        guard isShowingSearchResults else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        noResultsLayer.opacity = 0
        CATransaction.commit()
        showPages(layout.pages.map(\.items), isSearchResults: false, pageIndex: pageIndexBeforeSearch)
    }

    private func clearSearch() {
        searchText = ""
        searchTextDidChange()
    }

    // MARK: - Keys

    func handleKeyDown(keyCode: Int64, characters: String, modifierFlags: CGEventFlags) -> Action {
        let hasCommand = modifierFlags.contains(.maskCommand)
        switch keyCode {
        case SpringboardKeyCode.escape:
            // 15's order: close a folder, clear the search, then close Launchpad.
            guard searchText.isEmpty else {
                clearSearch()
                return .none
            }
            return .dismiss(reason: "escape")
        case SpringboardKeyCode.returnKey, SpringboardKeyCode.keypadEnter:
            return actionForSelectedItem()
        case SpringboardKeyCode.leftArrow where hasCommand:
            turnPageKeepingSelection(by: -1)
        case SpringboardKeyCode.rightArrow where hasCommand:
            turnPageKeepingSelection(by: 1)
        case SpringboardKeyCode.leftArrow:
            navigate(.left)
        case SpringboardKeyCode.rightArrow:
            navigate(.right)
        case SpringboardKeyCode.upArrow:
            navigate(.up)
        case SpringboardKeyCode.downArrow:
            navigate(.down)
        case SpringboardKeyCode.delete:
            guard !searchText.isEmpty else { return .none }
            searchText.removeLast()
            searchTextDidChange()
        case SpringboardKeyCode.tab:
            break
        default:
            guard
                !hasCommand,
                !modifierFlags.contains(.maskControl),
                !characters.isEmpty,
                !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) })
            else { return .none }
            searchText += characters
            searchTextDidChange()
        }
        return .none
    }

    private func navigate(_ direction: SpringboardNavigation.Direction) {
        let newIndex = SpringboardNavigation.selectedIndex(
            after: direction,
            from: selectedItemIndex,
            itemCount: currentItems.count,
            columnCount: metrics.input.columnCount
        )
        select(itemAt: newIndex)
    }

    /// Command-arrows turn the page; a selection moves to the new page's first item.
    private func turnPageKeepingSelection(by pageOffset: Int) {
        let hadSelection = selectedItemIndex != nil
        select(itemAt: nil)
        turn(toPageAt: currentPageIndex + pageOffset)
        if hadSelection, !currentItems.isEmpty {
            select(itemAt: 0)
        }
    }

    private func actionForSelectedItem() -> Action {
        guard let selectedItemIndex, currentItems.indices.contains(selectedItemIndex) else { return .none }
        guard case .application(let application) = currentItems[selectedItemIndex] else { return .none }
        let itemLayer = currentItemLayers.indices.contains(selectedItemIndex) ? currentItemLayers[selectedItemIndex] : nil
        return .launch(application, iconFrame: itemLayer.map(iconFrameInContainer(of:)) ?? .zero, iconImage: itemLayer?.imageLayer.contents)
    }

    // MARK: - Pointer

    private func pointInSpringboard(_ containerPoint: CGPoint) -> CGPoint {
        CGPoint(x: containerPoint.x - metrics.springboardFrame.minX, y: containerPoint.y - metrics.springboardFrame.minY)
    }

    /// The current page's grid layer and `containerPoint` in it.
    private func pointInCurrentGrid(_ containerPoint: CGPoint) -> (SpringboardPageGrid, CGPoint)? {
        guard pageGrids.indices.contains(currentPageIndex) else { return nil }
        let pageGrid = pageGrids[currentPageIndex]
        let springboardPoint = pointInSpringboard(containerPoint)
        let scrollContentPoint = CGPoint(
            x: springboardPoint.x - metrics.scrollFrame.minX + scrollValue,
            y: springboardPoint.y - metrics.scrollFrame.minY
        )
        let gridFrame = pageGrid.gridLayer.frame
        return (pageGrid, CGPoint(x: scrollContentPoint.x - gridFrame.minX, y: scrollContentPoint.y - gridFrame.minY))
    }

    private func iconFrameInContainer(of itemLayer: SpringboardItemLayer) -> CGRect {
        guard pageGrids.indices.contains(currentPageIndex) else { return .zero }
        let gridFrame = pageGrids[currentPageIndex].gridLayer.frame
        return itemLayer.iconFrame.offsetBy(
            dx: metrics.springboardFrame.minX + metrics.scrollFrame.minX - scrollValue + gridFrame.minX + itemLayer.frame.minX,
            dy: metrics.springboardFrame.minY + metrics.scrollFrame.minY + gridFrame.minY + itemLayer.frame.minY
        )
    }

    func handleMouseDown(at containerPoint: CGPoint, timestamp: UInt64) -> Action {
        wheelSettleTask?.cancel()
        let springboardPoint = pointInSpringboard(containerPoint)
        if metrics.searchFieldFrame.contains(springboardPoint) {
            let fieldPoint = CGPoint(x: springboardPoint.x - metrics.searchFieldFrame.minX, y: springboardPoint.y - metrics.searchFieldFrame.minY)
            if searchFieldLayer.isOnClearButton(fieldPoint) {
                searchFieldLayer.isClearButtonPressed = true
                pointerTracking = .clearButton
            } else {
                pointerTracking = .searchField
            }
            return .none
        }
        let pagerPoint = CGPoint(x: springboardPoint.x - metrics.pagerControlFrame.minX, y: springboardPoint.y - metrics.pagerControlFrame.minY)
        if let pageIndex = pagerControlLayer.pageIndex(at: pagerPoint) {
            pointerTracking = .pagerIndicator(pageIndex: pageIndex)
            return .none
        }
        if let (pageGrid, gridPoint) = pointInCurrentGrid(containerPoint), let hit = pageGrid.item(at: gridPoint), hit.isOnIcon {
            hit.itemLayer.isDarkened = true
            pointerTracking = .icon(pageIndex: currentPageIndex, itemIndex: hit.index, itemLayer: hit.itemLayer, startLocation: containerPoint)
            return .none
        }
        pointerTracking = .background(startLocation: containerPoint, startScrollValue: scrollValue, startTimestamp: timestamp, isDragging: false)
        return .none
    }

    func handleMouseDragged(to containerPoint: CGPoint, timestamp: UInt64) -> Action {
        switch pointerTracking {
        case let .icon(_, _, itemLayer, startLocation):
            // Rearranging comes with folders and dragging; until then a drag from an icon pages.
            guard hypot(containerPoint.x - startLocation.x, containerPoint.y - startLocation.y) >= SpringboardPaging.dragThreshold else { return .none }
            itemLayer.isDarkened = false
            pointerTracking = .background(startLocation: startLocation, startScrollValue: scrollValue, startTimestamp: timestamp, isDragging: true)
            return handleMouseDragged(to: containerPoint, timestamp: timestamp)
        case let .background(startLocation, startScrollValue, startTimestamp, isDragging):
            let horizontalMovement = containerPoint.x - startLocation.x
            let hasStartedDragging = isDragging || abs(horizontalMovement) >= SpringboardPaging.dragThreshold
            pointerTracking = .background(startLocation: startLocation, startScrollValue: startScrollValue, startTimestamp: startTimestamp, isDragging: hasStartedDragging)
            if hasStartedDragging {
                follow(scrollValue: startScrollValue - horizontalMovement)
            }
            return .none
        case .clearButton:
            let springboardPoint = pointInSpringboard(containerPoint)
            let fieldPoint = CGPoint(x: springboardPoint.x - metrics.searchFieldFrame.minX, y: springboardPoint.y - metrics.searchFieldFrame.minY)
            searchFieldLayer.isClearButtonPressed = searchFieldLayer.isOnClearButton(fieldPoint)
            return .none
        case .none, .pagerIndicator, .searchField:
            return .none
        }
    }

    func handleMouseUp(at containerPoint: CGPoint, timestamp: UInt64) -> Action {
        defer { pointerTracking = .none }
        switch pointerTracking {
        case let .icon(pageIndex, itemIndex, itemLayer, _):
            itemLayer.isDarkened = false
            guard
                pageIndex == currentPageIndex,
                let (pageGrid, gridPoint) = pointInCurrentGrid(containerPoint),
                let hit = pageGrid.item(at: gridPoint),
                hit.index == itemIndex,
                hit.isOnIcon
            else { return .none }
            switch hit.itemLayer.item {
            case .application(let application):
                return .launch(application, iconFrame: iconFrameInContainer(of: hit.itemLayer), iconImage: hit.itemLayer.imageLayer.contents)
            case .folder, .none:
                // Opening folders comes with the folder step.
                return .none
            }
        case let .background(startLocation, startScrollValue, startTimestamp, isDragging):
            guard isDragging else {
                // 15 closed on a click on the background, search or not (`cancelActionWithEvent:sender:`).
                let movement = hypot(containerPoint.x - startLocation.x, containerPoint.y - startLocation.y)
                return movement < SpringboardPaging.dragThreshold ? .dismiss(reason: "clicked outside the icons") : .none
            }
            let settledPageIndex = SpringboardPaging.settledPageIndex(
                currentPageIndex: currentPageIndex,
                pageCount: pageGrids.count,
                startScrollValue: startScrollValue,
                endScrollValue: scrollValue,
                elapsedNanoseconds: timestamp > startTimestamp ? timestamp - startTimestamp : 0
            )
            select(itemAt: nil)
            turn(toPageAt: settledPageIndex)
            return .none
        case .pagerIndicator(let pageIndex):
            let springboardPoint = pointInSpringboard(containerPoint)
            let pagerPoint = CGPoint(x: springboardPoint.x - metrics.pagerControlFrame.minX, y: springboardPoint.y - metrics.pagerControlFrame.minY)
            if pagerControlLayer.pageIndex(at: pagerPoint) == pageIndex {
                select(itemAt: nil)
                turn(toPageAt: pageIndex)
            }
            return .none
        case .clearButton:
            let wasPressed = searchFieldLayer.isClearButtonPressed
            searchFieldLayer.isClearButtonPressed = false
            if wasPressed {
                clearSearch()
            }
            return .none
        case .none, .searchField:
            return .none
        }
    }

    // MARK: - Scroll wheel and trackpad

    func handleScrollWheel(_ scrollWheel: SpringboardInputEvent.ScrollWheel, timestamp: UInt64) -> Action {
        // 15 ignored momentum: the content stops when the fingers lift.
        guard scrollWheel.momentumPhase == 0, !pageGrids.isEmpty else { return .none }
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
                select(itemAt: nil)
                trackpadScroll = (scrollValue, timestamp)
                follow(scrollValue: scrollValue + distance)
            case phaseEnded, phaseCancelled:
                guard let trackpadScroll else { return .none }
                self.trackpadScroll = nil
                let settledPageIndex = SpringboardPaging.settledPageIndex(
                    currentPageIndex: currentPageIndex,
                    pageCount: pageGrids.count,
                    startScrollValue: trackpadScroll.startScrollValue,
                    endScrollValue: scrollValue,
                    elapsedNanoseconds: timestamp > trackpadScroll.startTimestamp ? timestamp - trackpadScroll.startTimestamp : 0
                )
                turn(toPageAt: settledPageIndex)
            default:
                guard trackpadScroll != nil else { return .none }
                follow(scrollValue: scrollValue + distance)
            }
            return .none
        }

        // A notched wheel: follow, and settle on one page once the wheel pauses.
        guard distance != 0 else { return .none }
        select(itemAt: nil)
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
        return .none
    }

    /// What the Dock's grid made of the first page, for the log: classes, counts and a few frames.
    var firstPageSummary: String {
        guard let firstGrid = pageGrids.first else { return "no pages" }
        let itemLayers = firstGrid.itemLayers
        itemLayers.forEach { $0.layoutIfNeeded() }
        func describe(_ itemLayer: SpringboardItemLayer?) -> String {
            guard let itemLayer else { return "none" }
            return "cell \(NSStringFromRect(itemLayer.frame)) icon \(NSStringFromRect(itemLayer.iconFrame)) label \(NSStringFromRect(itemLayer.labelLayer.frame)) \"\(itemLayer.item?.title ?? "")\""
        }
        let gridClassName = String(cString: object_getClassName(firstGrid.gridLayer))
        let textClassName = String(cString: object_getClassName(itemLayers.first?.labelLayer.textLayer ?? CATextLayer()))
        let iconCount = itemLayers.filter { $0.imageLayer.contents != nil }.count
        return "grid \(gridClassName) \(NSStringFromRect(firstGrid.gridLayer.frame)), \(itemLayers.count)/\(firstGrid.items.count) items, titles \(textClassName), \(iconCount) with an image; first \(describe(itemLayers.first)); eighth \(describe(itemLayers.count > 7 ? itemLayers[7] : nil)); last \(describe(itemLayers.last))"
    }

    /// The geometry, for the log.
    var geometryDescription: String {
        "page \(Int(metrics.pageSize.width))×\(Int(metrics.pageSize.height)), cell \(Int(metrics.cellSize.width))×\(Int(metrics.cellSize.height)), icon \(Int(metrics.iconSide)), \(pageGrids.count) page(s), Dock \(metrics.input.dockOrientation.rawValue) \(Int(metrics.input.dockThickness)), notch \(Int(metrics.input.notchHeight))"
    }
}
