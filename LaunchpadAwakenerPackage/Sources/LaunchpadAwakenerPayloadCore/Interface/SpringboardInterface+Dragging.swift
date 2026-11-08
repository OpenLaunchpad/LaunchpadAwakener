import CoreGraphics
import Foundation
import QuartzCore
import UniformTypeIdentifiers

/// One icon being dragged; macOS 15's `ECSBDragCapture` with its stack of `ECSB*DragState`s, flattened.
///
/// The item's layer leaves its grid for the top of the container and follows the pointer, 1.1 times
/// larger. The page it is over is kept as an arrangement — that page's items in their new order, the
/// dragged one included — and the other icons are moved to match. Nothing is written until the drop.
@MainActor
final class SpringboardDragSession {
    let item: LaunchpadItem
    let itemLayer: SpringboardItemLayer
    let sourceContext: SpringboardInterface.GridContext
    let sourcePageIndex: Int
    let sourceItemIndex: Int
    /// For an application dragged out of a folder, the folder, and the main page it is on: unless that
    /// folder is open, a cancel sends the icon back into the folder's icon there.
    let sourceFolderIdentifier: LaunchpadItemIdentifier?
    let sourceFolderPageIndex: Int?
    /// The pointer's offset from the dragged cell's centre.
    let grabOffset: CGPoint

    var context: SpringboardInterface.GridContext
    var pageIndex: Int
    /// The current page's items as rearranged so far, the dragged one at `currentIndex`.
    var arrangement: [LaunchpadItem]
    /// The layers of `arrangement`; nil where the dragged item is.
    var arrangedLayers: [SpringboardItemLayer?]
    var currentIndex: Int
    var hasRearranged = false
    /// Whether the dragged icon has been over the open folder's panel; leaving it then closes the folder.
    var wasInsideFolderPanel: Bool
    /// Whether the current page was added past the last one during this drag.
    var isOnNewLastPage = false

    /// Set once the icon is let go: the drop is animating, and input waits until it ends.
    var isEnding = false
    /// A release that came while a folder was opening or closing; carried out once it has.
    var pendingDrop: (location: CGPoint, timestamp: UInt64)?
    /// Set from leaving a folder until its icon is back on the main page, 250 ms after it closed.
    var isWaitingForFolderToClose = false
    /// Set while a dragged search result waits for the results to fade out and its page to come in, as
    /// 15's `-[ECSBDragCapture _cancelFiltering]` (15.5 `0x1000B414C`) made it wait: the icon follows the
    /// pointer, nothing else responds.
    var isLeavingSearch = false
    /// An Escape that came while leaving the search; carried out once the page is in.
    var isCancelPending = false
    /// Whether the drag has arranged the main page around itself while starting from a folder: a search
    /// result joining the page, or an icon carried out of the folder. A cancel back into that folder puts
    /// the main page back as stored.
    var hasArrangedMainPage = false

    /// The main page as it was when a folder opened under the dragged icon: its icons, with a gap where
    /// the dragged one was. If the drag ends in the folder, the gap stays until the folder closes.
    var mainPageArrangement: (pageIndex: Int, arrangedLayers: [SpringboardItemLayer?])?
    /// The application held over until a new folder opened around it, with the folder's name; the folder
    /// is stored only by the drop.
    var unsavedFolderTarget: (application: LaunchpadApplication, title: String)?

    var lastLocation: CGPoint
    var lastTimestamp: UInt64
    var hoverTarget: (index: Int, itemLayer: SpringboardItemLayer)?
    var settleTask: Task<Void, Never>?
    var springLoadingTask: Task<Void, Never>?
    var edgeTask: Task<Void, Never>?
    var edgeDirection: Int?

    /// - Parameter origin: Where the item really is; the drag starts from there. For a search result that
    ///   is not the results it was picked up in.
    init(
        item: LaunchpadItem,
        itemLayer: SpringboardItemLayer,
        context: SpringboardInterface.GridContext,
        pageIndex: Int,
        itemIndex: Int,
        arrangement: [LaunchpadItem],
        arrangedLayers: [SpringboardItemLayer?],
        grabOffset: CGPoint,
        location: CGPoint,
        timestamp: UInt64,
        origin: SpringboardDragging.Location
    ) {
        self.item = item
        self.itemLayer = itemLayer
        switch origin {
        case let .mainPage(originPageIndex, originItemIndex):
            sourceContext = .main
            sourcePageIndex = originPageIndex
            sourceItemIndex = originItemIndex
            sourceFolderIdentifier = nil
            sourceFolderPageIndex = nil
        case let .folder(folderIdentifier, mainPageIndex, folderPageIndex, indexInFolder):
            sourceContext = .folder
            sourcePageIndex = folderPageIndex
            sourceItemIndex = indexInFolder
            sourceFolderIdentifier = folderIdentifier
            sourceFolderPageIndex = mainPageIndex
        }
        self.grabOffset = grabOffset
        self.context = context
        self.pageIndex = pageIndex
        self.arrangement = arrangement
        self.arrangedLayers = arrangedLayers
        currentIndex = itemIndex
        wasInsideFolderPanel = context == .folder
        lastLocation = location
        lastTimestamp = timestamp
    }

    func cancelTimers() {
        settleTask?.cancel()
        springLoadingTask?.cancel()
        edgeTask?.cancel()
        edgeDirection = nil
    }
}

extension SpringboardInterface {
    // MARK: - Starting

    func beginDrag(
        of itemLayer: SpringboardItemLayer,
        context: GridContext,
        pageIndex: Int,
        itemIndex: Int,
        startLocation: CGPoint,
        location: CGPoint,
        timestamp: UInt64
    ) {
        guard
            !isAnimatingFolder,
            let item = itemLayer.item,
            let pageGrid = pages(for: context).currentPageGrid,
            let itemSuperlayer = itemLayer.superlayer
        else {
            itemLayer.isDarkened = false
            return
        }
        // The drag starts from where the item really is: a search result from its application's place.
        let origin: SpringboardDragging.Location
        if isShowingSearchResults {
            guard let resultOrigin = SpringboardDragging.location(of: item.identifier, in: layout) else {
                itemLayer.isDarkened = false
                return
            }
            origin = resultOrigin
        } else if context == .folder, let folderPanel {
            origin = .folder(folderPanel.folder.identifier, mainPageIndex: mainPages.currentPageIndex, pageIndex: pageIndex, itemIndex: itemIndex)
        } else {
            origin = .mainPage(pageIndex: pageIndex, itemIndex: itemIndex)
        }
        let frameInContainer = itemSuperlayer.convert(itemLayer.frame, to: containerLayer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        itemLayer.removeFromSuperlayer()
        itemLayer.frame = frameInContainer
        containerLayer.addSublayer(itemLayer)
        CATransaction.commit()
        itemLayer.isMagnified = true
        // In jiggle mode 15 stopped the icon being dragged from shaking until it was put down.
        itemLayer.isHeldStill = true

        var arrangedLayers: [SpringboardItemLayer?] = pageGrid.itemLayers
        if arrangedLayers.indices.contains(itemIndex) {
            arrangedLayers[itemIndex] = nil
        }
        dragSession = SpringboardDragSession(
            item: item,
            itemLayer: itemLayer,
            context: context,
            pageIndex: pageIndex,
            itemIndex: itemIndex,
            arrangement: pageGrid.items,
            arrangedLayers: arrangedLayers,
            grabOffset: CGPoint(x: frameInContainer.midX - startLocation.x, y: frameInContainer.midY - startLocation.y),
            location: location,
            timestamp: timestamp,
            origin: origin
        )
        if isShowingSearchResults {
            leaveSearchForDraggedResult()
        }
        continueDrag(to: location, timestamp: timestamp)
    }

    /// The first move of a dragged search result ends the search, as 15's did (`-[ECSBDragCapture
    /// _cancelFiltering]`, 15.5 `0x1000B414C`, and its completion blocks `0x1000B42B8` and `0x1000B4388`):
    /// the results fade out, the search is cleared, the page shown before it comes back with the result's
    /// application after its other items, and the page fades in.
    private func leaveSearchForDraggedResult() {
        guard let dragSession else { return }
        dragSession.isLeavingSearch = true
        // Wherever it ends up, the application moves from where it is.
        dragSession.hasRearranged = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dragSession === dragSession, dragSession.isLeavingSearch else { return }
                self.joinPageBeforeSearch(dragSession)
            }
        }
        mainPages.scrollLayer.opacity = 0
        CATransaction.commit()
    }

    private func joinPageBeforeSearch(_ dragSession: SpringboardDragSession) {
        clearSearch()
        // The application's own icons leave the pages, as 15 took them out (`removeItemLayer:`); the
        // dragged icon stands for it. A folder it is in keeps showing it until the drop.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for itemLayer in mainPages.itemLayers where itemLayer.item?.identifier == dragSession.item.identifier {
            itemLayer.removeFromSuperlayer()
        }
        CATransaction.commit()
        if let pageGrid = mainPages.currentPageGrid {
            let joined = SpringboardDragging.arrangement(
                joining: dragSession.item,
                page: zip(pageGrid.items, pageGrid.itemLayers).map { (item: $0, layer: $1) },
                capacity: pageGrid.capacity
            )
            dragSession.context = .main
            dragSession.pageIndex = mainPages.currentPageIndex
            dragSession.arrangement = joined.items
            dragSession.arrangedLayers = joined.layers
            dragSession.currentIndex = joined.index
            dragSession.hasArrangedMainPage = true
            animateArrangement()
        }
        dragSession.isLeavingSearch = false
        mainPages.scrollLayer.opacity = 1
        if dragSession.isCancelPending {
            cancelDrag()
        } else if dragSession.pendingDrop != nil {
            performPendingDrop()
        } else {
            // 15 left the page alone until the next move; a pointer still moving fast keeps it so.
            evaluateDragOnceSettled()
        }
    }

    // MARK: - Moving

    func continueDrag(to location: CGPoint, timestamp: UInt64) {
        guard let dragSession, !dragSession.isEnding else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dragSession.itemLayer.position = CGPoint(x: location.x + dragSession.grabOffset.x, y: location.y + dragSession.grabOffset.y)
        CATransaction.commit()

        let speed = SpringboardDragging.speed(
            from: dragSession.lastLocation,
            to: location,
            elapsedNanoseconds: timestamp > dragSession.lastTimestamp ? timestamp - dragSession.lastTimestamp : 0
        )
        dragSession.lastLocation = location
        dragSession.lastTimestamp = timestamp
        // While the pointer is fast, nothing responds; it does once the pointer slows down or rests.
        if speed >= SpringboardDragging.settlingSpeedThreshold {
            evaluateDragOnceSettled()
        } else {
            dragSession.settleTask?.cancel()
            evaluateDrag()
        }
    }

    /// Responds to where the dragged icon is once no move has come for the settling delay.
    private func evaluateDragOnceSettled() {
        guard let dragSession else { return }
        dragSession.settleTask?.cancel()
        dragSession.settleTask = Task { [weak self] in
            try? await Task.sleep(for: SpringboardDragging.settlingDelay)
            guard !Task.isCancelled else { return }
            self?.evaluateDrag()
        }
    }

    /// Decides what the dragged icon's position means, in 15's order: leaving the open folder, an edge,
    /// another icon to drop onto, then a new place on the page.
    private func evaluateDrag() {
        guard let dragSession, !dragSession.isEnding, !dragSession.isWaitingForFolderToClose, !dragSession.isLeavingSearch, !isAnimatingFolder else { return }
        let cellCenter = dragSession.itemLayer.position

        if let folderPanel {
            let iconRect = dragSession.itemLayer.convert(dragSession.itemLayer.iconFrame, to: containerLayer)
            let panelRect = folderPanel.folderLayer.convert(folderPanel.folderMetrics.panelFrame, to: containerLayer)
            if iconRect.intersects(panelRect) {
                dragSession.wasInsideFolderPanel = true
            } else if dragSession.wasInsideFolderPanel {
                leaveFolder()
                return
            }
        }

        let pages = pages(for: dragSession.context)
        guard let pageGrid = pages.currentPageGrid else { return }
        let gridFrame = pageGrid.gridLayer.convert(pageGrid.gridLayer.bounds, to: containerLayer)
        if cellCenter.x < gridFrame.minX {
            scheduleEdgePageTurn(direction: -1)
            return
        }
        if cellCenter.x > gridFrame.maxX {
            scheduleEdgePageTurn(direction: 1)
            return
        }
        cancelEdgePageTurn()

        let pointFromTopLeft = pageGrid.pointFromTopLeft(containerLayer.convert(cellCenter, to: pageGrid.gridLayer))
        if dragSession.context == .main, folderPanel == nil, case .application = dragSession.item {
            let targetIndex = SpringboardDragging.itemIndex(
                at: pointFromTopLeft,
                cellSize: pageGrid.cellSize,
                columnCount: pageGrid.columnCount,
                // An item pushed past a full page waits to spill over; the grid ends at its capacity.
                itemCount: min(dragSession.arrangement.count, pageGrid.capacity),
                currentIndex: nil,
                usesHysteresis: false
            )
            if targetIndex != dragSession.currentIndex,
               dragSession.arrangedLayers.indices.contains(targetIndex),
               let targetLayer = dragSession.arrangedLayers[targetIndex],
               targetLayer.convert(targetLayer.iconFrame, to: containerLayer).contains(cellCenter)
            {
                hover(over: targetIndex, targetLayer: targetLayer)
                return
            }
        }
        endHover()

        let newIndex = SpringboardDragging.itemIndex(
            at: pointFromTopLeft,
            cellSize: pageGrid.cellSize,
            columnCount: pageGrid.columnCount,
            itemCount: min(dragSession.arrangement.count, pageGrid.capacity),
            currentIndex: dragSession.currentIndex,
            usesHysteresis: true
        )
        if newIndex != dragSession.currentIndex {
            moveDraggedItem(to: newIndex)
        }
    }

    private func moveDraggedItem(to newIndex: Int) {
        guard let dragSession else { return }
        let item = dragSession.arrangement.remove(at: dragSession.currentIndex)
        dragSession.arrangement.insert(item, at: newIndex)
        let layer = dragSession.arrangedLayers.remove(at: dragSession.currentIndex)
        dragSession.arrangedLayers.insert(layer, at: newIndex)
        dragSession.currentIndex = newIndex
        dragSession.hasRearranged = true
        animateArrangement()
    }

    /// Moves every icon of the current page to its place in the arrangement, making room in 0.4 s unless
    /// told otherwise; icons pushed past the page's capacity hide until they spill over on the drop.
    func animateArrangement(duration: CFTimeInterval = SpringboardDragging.makeRoomDuration, completion: (@MainActor () -> Void)? = nil) {
        guard let dragSession, let pageGrid = pages(for: dragSession.context).currentPageGrid else {
            completion?()
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        if let completion {
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    completion()
                }
            }
        }
        for (index, layer) in dragSession.arrangedLayers.enumerated() {
            guard let layer else { continue }
            // Not `frame`: an icon may be scaled at this moment, a folder dissolving for one.
            layer.setUntransformedFrame(pageGrid.cellFrame(at: index))
            layer.opacity = index < pageGrid.capacity ? 1 : 0
        }
        CATransaction.commit()
    }

    // MARK: - Dropping onto another icon

    private func hover(over targetIndex: Int, targetLayer: SpringboardItemLayer) {
        guard let dragSession, dragSession.hoverTarget?.index != targetIndex else { return }
        endHover()
        dragSession.hoverTarget = (targetIndex, targetLayer)
        targetLayer.isDropTarget = true
        // 15 stopped the icon held over from shaking, and let it shake again once left.
        targetLayer.isHeldStill = true
        dragSession.itemLayer.isMagnified = false
        dragSession.itemLayer.labelLayer.opacity = 0
        // Holding on opens a folder, or turns an application into a new folder and opens that.
        dragSession.springLoadingTask = Task { [weak self] in
            try? await Task.sleep(for: SpringboardDragging.springLoadingDelay)
            guard !Task.isCancelled, let self else { return }
            switch targetLayer.item {
            case .folder(let folder):
                self.springLoad(folder, folderItemLayer: targetLayer)
            case .application(let application):
                self.springLoadNewFolder(around: application, targetLayer: targetLayer)
            case .none:
                break
            }
        }
    }

    func endHover() {
        guard let dragSession, let hoverTarget = dragSession.hoverTarget else { return }
        dragSession.springLoadingTask?.cancel()
        dragSession.hoverTarget = nil
        hoverTarget.itemLayer.isDropTarget = false
        hoverTarget.itemLayer.isHeldStill = false
        dragSession.itemLayer.isMagnified = true
    }

    /// Opens a held-over folder and carries the dragged icon into it, placed after the last item of its
    /// first page. The dragged icon's cell on the main page stays empty meanwhile, as 15 left it.
    private func springLoad(_ folder: LaunchpadFolder, folderItemLayer: SpringboardItemLayer) {
        guard let dragSession, folderPanel == nil, !isAnimatingFolder else { return }
        endHover()
        cancelEdgePageTurn()
        dragSession.mainPageArrangement = (dragSession.pageIndex, dragSession.arrangedLayers)
        openFolder(folder, from: folderItemLayer) { [weak self] in
            self?.carryDraggedItemIntoOpenFolder()
        }
        keepDraggedIconOnTop()
    }

    /// Once a folder opened under the dragged icon: the icon belongs to the folder's current page now,
    /// after its last item.
    func carryDraggedItemIntoOpenFolder() {
        guard let dragSession, !dragSession.isEnding, let folderPanel, let currentPage = folderPanel.pages.currentPageGrid else { return }
        // An application carried back into its own folder — a search result held over it — leaves its own
        // icons there; the dragged one stands for it, as on the main pages.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for itemLayer in folderPanel.pages.itemLayers where itemLayer.item?.identifier == dragSession.item.identifier {
            itemLayer.removeFromSuperlayer()
        }
        CATransaction.commit()
        let joined = SpringboardDragging.arrangement(
            joining: dragSession.item,
            page: zip(currentPage.items, currentPage.itemLayers).map { (item: $0, layer: $1) },
            capacity: currentPage.capacity
        )
        dragSession.context = .folder
        dragSession.pageIndex = folderPanel.pages.currentPageIndex
        dragSession.arrangement = joined.items
        dragSession.arrangedLayers = joined.layers
        dragSession.currentIndex = joined.index
        dragSession.wasInsideFolderPanel = true
        dragSession.hasRearranged = true
        keepDraggedIconOnTop()
        performPendingDrop()
    }

    /// Puts the dragged icon back on top of everything, the open folder's panel included.
    func keepDraggedIconOnTop() {
        guard let dragSession else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.addSublayer(dragSession.itemLayer)
        CATransaction.commit()
    }

    /// Carries out a release that came while a folder was opening or closing.
    func performPendingDrop() {
        guard let dragSession, let pendingDrop = dragSession.pendingDrop else { return }
        dragSession.pendingDrop = nil
        endDrag(at: pendingDrop.location, timestamp: pendingDrop.timestamp)
    }

    /// The dragged icon left the open folder: close it and carry the icon to the end of the main page —
    /// onto its last cell when the page is full (`-[ECSBCloseGroupDragState beginTransition]`,
    /// 15.5 `0x10011FE08`). 250 ms after the folder has closed, the main page closes the gap the icon may
    /// have left there, and a folder left with one application or none dissolves into it.
    private func leaveFolder() {
        guard let dragSession, let folderPanel else { return }
        cancelEdgePageTurn()
        let folderItemLayer = self.folderItemLayer(of: folderPanel.folder)
        let remainingApplications = folderPanel.folder.applications.filter { $0.identifier != dragSession.item.identifier }
        let dissolves = folderPanel.folder.isUnsaved || remainingApplications.count <= 1
        if let folderItemLayer, remainingApplications.count != folderPanel.folder.applications.count {
            // The folder's icon shows the folder without the dragged application as it closes, as 15
            // refreshed it (`-[ECSBGroupLayer prepareForAnimatedHide]`, 15.5 `0x10004E404`).
            let remainingFolder = folderPanel.folder.removing(dragSession.item.identifier)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            folderItemLayer.configure(with: .folder(remainingFolder), metrics: metrics, scale: scale)
            putIcons(in: folderItemLayer)
            folderItemLayer.layoutIfNeeded()
            CATransaction.commit()
        }
        // The main page as a drag left it when the folder opened — this drag, or the one whose drop opened
        // the folder by itself; its gap is dropped below. This drag now moves the main page, so the gap no
        // longer waits for the folder to close.
        let mainPageArrangement = dragSession.mainPageArrangement ?? mainPagePlaceholder
        mainPagePlaceholder = nil
        dragSession.isWaitingForFolderToClose = true
        dragSession.unsavedFolderTarget = nil
        dragSession.mainPageArrangement = nil
        closeFolder()

        if let mainPage = mainPages.currentPageGrid {
            var arrangement: [LaunchpadItem]
            var arrangedLayers: [SpringboardItemLayer?]
            if let mainPageArrangement, mainPageArrangement.pageIndex == mainPages.currentPageIndex {
                let stashedLayers = mainPageArrangement.arrangedLayers.compactMap { $0 }.filter { $0.item != nil }
                arrangedLayers = stashedLayers
                arrangement = stashedLayers.compactMap(\.item)
            } else {
                arrangement = mainPage.items
                arrangedLayers = mainPage.itemLayers
            }
            if let draggedIndex = arrangement.firstIndex(where: { $0.identifier == dragSession.item.identifier }) {
                arrangement.remove(at: draggedIndex)
                arrangedLayers.remove(at: draggedIndex)
            }
            if dissolves, let folderItemLayer, let folderIndex = arrangedLayers.firstIndex(where: { $0 === folderItemLayer }) {
                if let remainingApplication = remainingApplications.first {
                    arrangement[folderIndex] = .application(remainingApplication)
                } else {
                    arrangement.remove(at: folderIndex)
                    arrangedLayers.remove(at: folderIndex)
                }
            }
            let insertionIndex = min(arrangement.count, mainPage.capacity - 1)
            arrangement.insert(dragSession.item, at: insertionIndex)
            arrangedLayers.insert(nil, at: insertionIndex)
            dragSession.context = .main
            dragSession.pageIndex = mainPages.currentPageIndex
            dragSession.arrangement = arrangement
            dragSession.arrangedLayers = arrangedLayers
            dragSession.currentIndex = insertionIndex
            dragSession.wasInsideFolderPanel = false
            dragSession.hasRearranged = true
            dragSession.hasArrangedMainPage = true
        }

        // The panel closes in 0.25 s; 250 ms later the main page moves (`Pager_hideGroupAfter250ms`).
        DispatchQueue.main.asyncAfter(deadline: .now() + SpringboardFolderPanel.animationDuration + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dragSession === dragSession, !dragSession.isEnding else { return }
                dragSession.isWaitingForFolderToClose = false
                self.animateArrangement(duration: SpringboardFolderPanel.animationDuration)
                if dissolves, let folderItemLayer {
                    self.dissolveFolderIcon(folderItemLayer, into: remainingApplications.first)
                }
                self.performPendingDrop()
            }
        }
    }

    private func removeDraggedItemFromArrangement() {
        guard let dragSession else { return }
        dragSession.arrangement.remove(at: dragSession.currentIndex)
        dragSession.arrangedLayers.remove(at: dragSession.currentIndex)
        dragSession.currentIndex = dragSession.arrangement.count
        animateArrangement()
    }

    // MARK: - Edges

    private func scheduleEdgePageTurn(direction: Int) {
        guard let dragSession, dragSession.edgeDirection != direction else { return }
        endHover()
        cancelEdgePageTurn()
        dragSession.edgeDirection = direction
        dragSession.edgeTask = Task { [weak self] in
            try? await Task.sleep(for: SpringboardDragging.edgePageTurnDelay)
            while !Task.isCancelled {
                self?.turnPageWhileDragging(direction: direction)
                try? await Task.sleep(for: SpringboardDragging.edgePageTurnRepeatInterval)
            }
        }
    }

    func cancelEdgePageTurn() {
        dragSession?.edgeTask?.cancel()
        dragSession?.edgeDirection = nil
    }

    /// Carries the dragged icon to the end of the neighbouring page; past the last main page, to a new
    /// one if this page has anything else on it.
    private func turnPageWhileDragging(direction: Int) {
        guard let dragSession, !isAnimatingFolder else { return }
        let pages = pages(for: dragSession.context)
        let targetPageIndex = dragSession.pageIndex + direction
        guard targetPageIndex >= 0 else { return }
        if targetPageIndex >= pages.pageGrids.count {
            guard dragSession.context == .main, dragSession.arrangement.count > 1 else { return }
            pages.appendEmptyPage(rowCount: metrics.input.rowCount) { [weak self] itemLayer in
                self?.putIcons(in: itemLayer)
            }
            dragSession.isOnNewLastPage = true
        }
        removeDraggedItemFromArrangement()
        pages.turn(toPageAt: targetPageIndex)
        guard let targetPage = pages.currentPageGrid else { return }
        let joined = SpringboardDragging.arrangement(
            joining: dragSession.item,
            page: zip(targetPage.items, targetPage.itemLayers).map { (item: $0, layer: $1) },
            capacity: targetPage.capacity
        )
        dragSession.arrangement = joined.items
        dragSession.arrangedLayers = joined.layers
        dragSession.currentIndex = joined.index
        dragSession.pageIndex = pages.currentPageIndex
        dragSession.isOnNewLastPage = dragSession.context == .main && targetPageIndex >= layout.pages.count
        dragSession.hasRearranged = true
        animateArrangement()
    }


    // MARK: - Dropping

    func endDrag(at location: CGPoint, timestamp: UInt64) {
        guard let dragSession, !dragSession.isEnding else { return }
        // A release while a folder opens or closes, or while the search goes, waits for it to finish, as
        // 15's did.
        if isAnimatingFolder || dragSession.isWaitingForFolderToClose || dragSession.isLeavingSearch {
            dragSession.pendingDrop = (location, timestamp)
            return
        }
        dragSession.cancelTimers()

        if let hoverTarget = dragSession.hoverTarget, let targetItem = hoverTarget.itemLayer.item {
            dragSession.isEnding = true
            switch targetItem {
            case .application(let targetApplication):
                let title = defaultFolderName(for: targetApplication)
                applyEdit(.makeFolder(merging: dragSession.item.identifier, with: targetApplication.identifier, title: title))
                dropIntoNewFolder(around: targetApplication, targetLayer: hoverTarget.itemLayer, title: title)
            case .folder(let folder):
                applyEdit(.moveIntoFolder(dragSession.item.identifier, folder: folder.identifier))
                dropIntoFolder(folder, folderItemLayer: hoverTarget.itemLayer)
            }
            return
        }

        guard dragSession.hasRearranged || dragSession.context != dragSession.sourceContext else {
            cancelDrag()
            return
        }
        guard let edit = editForDrop(), let pageGrid = pages(for: dragSession.context).currentPageGrid else {
            cancelDrag()
            return
        }
        dragSession.isEnding = true
        applyEdit(edit)
        let targetIndex = min(dragSession.currentIndex, max(pageGrid.capacity - 1, 0))
        let cellFrameInGrid = pageGrid.cellFrame(at: targetIndex)
        let gridLayer = pageGrid.gridLayer
        // The layer the grid keeps its items in; it covers the grid exactly.
        let itemsLayer = pageGrid.itemLayers.first?.superlayer ?? gridLayer
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                // Back into the grid until the stored layout replaces the page.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                dragSession.itemLayer.removeFromSuperlayer()
                dragSession.itemLayer.transform = CATransform3DIdentity
                dragSession.itemLayer.frame = cellFrameInGrid
                itemsLayer.addSublayer(dragSession.itemLayer)
                CATransaction.commit()
                self.finishDrag()
            }
        }
        dragSession.itemLayer.isMagnified = false
        dragSession.itemLayer.isDarkened = false
        let targetFrame = gridLayer.convert(cellFrameInGrid, to: containerLayer)
        dragSession.itemLayer.position = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        CATransaction.commit()
    }

    /// What the drop writes, from where the dragged item ended up.
    private func editForDrop() -> LaunchpadEdit? {
        guard let dragSession else { return nil }
        let itemIdentifier = dragSession.item.identifier
        switch dragSession.context {
        case .main:
            if dragSession.isOnNewLastPage {
                return .moveToNewLastPage(itemIdentifier)
            }
            guard layout.pages.indices.contains(dragSession.pageIndex) else { return nil }
            let pageIdentifier = layout.pages[dragSession.pageIndex].identifier
            if dragSession.sourceContext == .folder {
                return .moveOutOfFolder(itemIdentifier, toIndex: dragSession.currentIndex, onPage: pageIdentifier)
            }
            return .move(itemIdentifier, toIndex: dragSession.currentIndex, onPage: pageIdentifier)
        case .folder:
            if let unsavedFolderTarget = dragSession.unsavedFolderTarget {
                // Released in a folder opened by holding over an application: the folder is made now, in
                // the order its panel shows.
                return .makeFolder(
                    merging: itemIdentifier,
                    with: unsavedFolderTarget.application.identifier,
                    title: unsavedFolderTarget.title,
                    draggedItemIndex: dragSession.currentIndex == 0 ? 0 : 1
                )
            }
            guard let folderPanel, folderPanel.folder.pages.indices.contains(dragSession.pageIndex) else { return nil }
            return .move(itemIdentifier, toIndex: dragSession.currentIndex, onPage: folderPanel.folder.pages[dragSession.pageIndex].identifier)
        }
    }

    /// 15 named a new folder after the target application's category, or "Untitled".
    func defaultFolderName(for application: LaunchpadApplication) -> String {
        if
            let bundleURL = application.bundleURL,
            let categoryIdentifier = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
            let categoryDescription = UTType(categoryIdentifier)?.localizedDescription
        {
            return categoryDescription
        }
        return Bundle.main.localizedString(forKey: "Untitled", value: "Untitled", table: nil)
    }

    /// Escape, or a drop that changed nothing: everything slides back where it was. A folder the drag
    /// opened closes as usual while the main page is rebuilt from the stored layout. A drop already
    /// animating is left to finish.
    func cancelDrag() {
        guard let dragSession, !dragSession.isEnding else { return }
        // While a dragged search result leaves the search, the cancel waits until its page is in, as 15's
        // waited (`sub_1000B4388`).
        if dragSession.isLeavingSearch {
            dragSession.isCancelPending = true
            return
        }
        dragSession.isEnding = true
        dragSession.cancelTimers()
        dragSession.mainPageArrangement = nil
        dragSession.unsavedFolderTarget = nil
        endHover()
        var closingFolder: LaunchpadFolder?
        let (route, closesOpenFolder) = SpringboardDragging.cancelRoute(
            sourceFolder: dragSession.sourceFolderIdentifier,
            openFolder: folderPanel?.folder.identifier
        )
        if let folderPanel, closesOpenFolder {
            closingFolder = folderPanel.folder
            if isAnimatingFolder {
                dismissFolderImmediately()
            } else {
                closeFolder()
            }
        }
        if route == .folderIcon {
            // Dragged out of a folder that has closed since — another one may have opened meanwhile — or
            // out of a closed one as a search result: back into the folder's icon, as 15 did.
            showMainPages(pageIndex: dragSession.sourceFolderPageIndex ?? mainPages.currentPageIndex)
            if let closingFolder, folderPanel != nil {
                hideFolderIcon(of: closingFolder)
            }
            let folderIconLayer = mainPages.itemLayers.first { $0.item?.identifier == dragSession.sourceFolderIdentifier }
                ?? mainPages.itemLayers.first { itemLayer in
                    guard case .folder(let folder) = itemLayer.item else { return false }
                    return folder.applications.contains { $0.identifier == dragSession.item.identifier }
                }
            guard let folderIconLayer else {
                dragSession.itemLayer.removeFromSuperlayer()
                finishDrag()
                return
            }
            slideDraggedLayer(intoFolderIcon: folderIconLayer) { [weak self] in
                self?.finishDrag()
            }
            return
        }
        // Rebuild the pages the drag started on from the stored layout, then send the icon home.
        let sourcePages = pages(for: route == .openFolderCell ? .folder : .main)
        if route == .mainPageCell {
            showMainPages(pageIndex: dragSession.sourcePageIndex)
            if let closingFolder, folderPanel != nil {
                // The closing panel shrinks onto the rebuilt page's icon of its folder, shown once it has.
                hideFolderIcon(of: closingFolder)
            }
        } else if let folderPanel {
            // The folder as stored: the open one may be a copy without the dragged application, opened by
            // holding the icon over it after it had left.
            folderPanel.reload(with: storedFolder(for: folderPanel.folder, in: layout) ?? folderPanel.folder, pageIndex: dragSession.sourcePageIndex) { [weak self] itemLayer in
                self?.putIcons(in: itemLayer)
            }
            if dragSession.hasArrangedMainPage {
                // The main page behind is still arranged around the drag — a search result joined it, or
                // the icon left this folder and came back: it goes back to the stored layout too.
                showMainPages(pageIndex: mainPages.currentPageIndex)
                hideFolderIcon(of: folderPanel.folder)
            }
        }
        guard
            let homeGrid = sourcePages.currentPageGrid,
            homeGrid.itemLayers.indices.contains(dragSession.sourceItemIndex)
        else {
            dragSession.itemLayer.removeFromSuperlayer()
            finishDrag()
            return
        }
        let homeLayer = homeGrid.itemLayers[dragSession.sourceItemIndex]
        let homeFrame = homeGrid.gridLayer.convert(homeGrid.cellFrame(at: dragSession.sourceItemIndex), to: containerLayer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        homeLayer.opacity = 0
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                homeLayer.opacity = 1
                dragSession.itemLayer.removeFromSuperlayer()
                CATransaction.commit()
                self.finishDrag()
            }
        }
        dragSession.itemLayer.isMagnified = false
        dragSession.itemLayer.isDarkened = false
        dragSession.itemLayer.position = CGPoint(x: homeFrame.midX, y: homeFrame.midY)
        CATransaction.commit()
    }

    /// Sends the dragged icon back into a closed folder's icon: it slides there, shrinking to a
    /// thumbnail's size and fading to half (`-[ECSBBeginningDragState _restoreItemLayer:…]`, 15.5
    /// `0x10010D574`), then goes.
    private func slideDraggedLayer(intoFolderIcon folderIconLayer: SpringboardItemLayer, completion: @escaping @MainActor () -> Void) {
        guard let dragSession else { return }
        let folderIconRect = folderIconLayer.convert(folderIconLayer.iconFrame, to: containerLayer)
        let thumbnailScale = SpringboardItemLayer.thumbnailSide(forIconSide: metrics.iconSide) / max(metrics.iconSide, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                dragSession.itemLayer.removeFromSuperlayer()
                completion()
            }
        }
        dragSession.itemLayer.position = CGPoint(x: folderIconRect.midX, y: folderIconRect.midY)
        dragSession.itemLayer.transform = CATransform3DMakeScale(thumbnailScale, thumbnailScale, 1)
        dragSession.itemLayer.opacity = 0.5
        CATransaction.commit()
    }

    /// Ends the drag. One that ended in a folder it opened leaves the main page with its gap until that
    /// folder closes.
    func finishDrag() {
        if let dragSession, let mainPageArrangement = dragSession.mainPageArrangement, folderPanel != nil {
            mainPagePlaceholder = mainPageArrangement
        }
        // Put down, the icon shakes again if its pages are in jiggle mode.
        dragSession?.itemLayer.isHeldStill = false
        dragSession?.cancelTimers()
        dragSession = nil
        applyPendingLayoutIfIdle()
    }
}
