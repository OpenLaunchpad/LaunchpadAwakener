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

    var lastLocation: CGPoint
    var lastTimestamp: UInt64
    var hoverTarget: (index: Int, itemLayer: SpringboardItemLayer)?
    var settleTask: Task<Void, Never>?
    var springLoadingTask: Task<Void, Never>?
    var edgeTask: Task<Void, Never>?
    var edgeDirection: Int?

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
        timestamp: UInt64
    ) {
        self.item = item
        self.itemLayer = itemLayer
        sourceContext = context
        sourcePageIndex = pageIndex
        sourceItemIndex = itemIndex
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
        // 15 left search on the first move of a dragged result; here results are not dragged.
        guard
            !isShowingSearchResults,
            !isAnimatingFolder,
            let item = itemLayer.item,
            let pageGrid = pages(for: context).currentPageGrid,
            let itemSuperlayer = itemLayer.superlayer
        else {
            itemLayer.isDarkened = false
            return
        }
        let frameInContainer = itemSuperlayer.convert(itemLayer.frame, to: containerLayer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        itemLayer.removeFromSuperlayer()
        itemLayer.frame = frameInContainer
        containerLayer.addSublayer(itemLayer)
        CATransaction.commit()
        itemLayer.isMagnified = true

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
            timestamp: timestamp
        )
        continueDrag(to: location, timestamp: timestamp)
    }

    // MARK: - Moving

    func continueDrag(to location: CGPoint, timestamp: UInt64) {
        guard let dragSession else { return }
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
        dragSession.settleTask?.cancel()
        // While the pointer is fast, nothing responds; it does once the pointer slows down or rests.
        if speed >= SpringboardDragging.settlingSpeedThreshold {
            dragSession.settleTask = Task { [weak self] in
                try? await Task.sleep(for: SpringboardDragging.settlingDelay)
                guard !Task.isCancelled else { return }
                self?.evaluateDrag()
            }
        } else {
            evaluateDrag()
        }
    }

    /// Decides what the dragged icon's position means, in 15's order: leaving the open folder, an edge,
    /// another icon to drop onto, then a new place on the page.
    private func evaluateDrag() {
        guard let dragSession, !isAnimatingFolder else { return }
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
                itemCount: dragSession.arrangement.count,
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
            itemCount: dragSession.arrangement.count,
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

    /// Moves every icon of the current page to its place in the arrangement, making room in 0.4 s;
    /// icons pushed past the page's capacity hide until they spill over on the drop.
    private func animateArrangement() {
        guard let dragSession, let pageGrid = pages(for: dragSession.context).currentPageGrid else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(SpringboardDragging.makeRoomDuration)
        for (index, layer) in dragSession.arrangedLayers.enumerated() {
            guard let layer else { continue }
            layer.frame = pageGrid.cellFrame(at: index)
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
        dragSession.itemLayer.isMagnified = false
        dragSession.itemLayer.labelLayer.opacity = 0
        // Holding over a folder opens it (15 also turned an application into a new folder and opened
        // that; here a new folder is made on the drop instead).
        if case .folder(let folder) = targetLayer.item {
            dragSession.springLoadingTask = Task { [weak self] in
                try? await Task.sleep(for: SpringboardDragging.springLoadingDelay)
                guard !Task.isCancelled else { return }
                self?.springLoad(folder, folderItemLayer: targetLayer)
            }
        }
    }

    private func endHover() {
        guard let dragSession, let hoverTarget = dragSession.hoverTarget else { return }
        dragSession.springLoadingTask?.cancel()
        dragSession.hoverTarget = nil
        hoverTarget.itemLayer.isDropTarget = false
        dragSession.itemLayer.isMagnified = true
    }

    /// Opens a held-over folder and carries the dragged icon into it, placed after its last item.
    private func springLoad(_ folder: LaunchpadFolder, folderItemLayer: SpringboardItemLayer) {
        guard dragSession != nil, folderPanel == nil else { return }
        endHover()
        cancelEdgePageTurn()
        removeDraggedItemFromArrangement()
        openFolder(folder, from: folderItemLayer) { [weak self] in
            guard let self, let dragSession = self.dragSession, let folderPanel = self.folderPanel, let firstPage = folderPanel.pages.currentPageGrid else { return }
            dragSession.context = .folder
            dragSession.pageIndex = folderPanel.pages.currentPageIndex
            dragSession.arrangement = firstPage.items + [dragSession.item]
            dragSession.arrangedLayers = firstPage.itemLayers.map(Optional.some) + [nil]
            dragSession.currentIndex = dragSession.arrangement.count - 1
            dragSession.wasInsideFolderPanel = true
            // Keep the dragged icon above the panel that just appeared.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.containerLayer.addSublayer(dragSession.itemLayer)
            CATransaction.commit()
        }
    }

    /// The dragged icon left the open folder: close it and carry the icon to the end of the main page —
    /// onto its last cell when the page is full (`-[ECSBCloseGroupDragState beginTransition]`).
    private func leaveFolder() {
        guard let dragSession, folderPanel != nil else { return }
        cancelEdgePageTurn()
        closeFolder()
        guard let mainPage = mainPages.currentPageGrid else { return }
        var arrangement = mainPage.items
        var arrangedLayers: [SpringboardItemLayer?] = mainPage.itemLayers
        if let draggedIndex = arrangement.firstIndex(where: { $0.identifier == dragSession.item.identifier }) {
            arrangement.remove(at: draggedIndex)
            arrangedLayers.remove(at: draggedIndex)
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
        animateArrangement()
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

    private func cancelEdgePageTurn() {
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
        var arrangement = targetPage.items
        var arrangedLayers: [SpringboardItemLayer?] = targetPage.itemLayers
        if let draggedIndex = arrangement.firstIndex(where: { $0.identifier == dragSession.item.identifier }) {
            arrangement.remove(at: draggedIndex)
            arrangedLayers.remove(at: draggedIndex)
        }
        dragSession.arrangement = arrangement + [dragSession.item]
        dragSession.arrangedLayers = arrangedLayers + [nil]
        dragSession.currentIndex = dragSession.arrangement.count - 1
        dragSession.pageIndex = pages.currentPageIndex
        dragSession.isOnNewLastPage = dragSession.context == .main && targetPageIndex >= layout.pages.count
        dragSession.hasRearranged = true
        animateArrangement()
    }

    // MARK: - Dropping

    func endDrag(at location: CGPoint, timestamp: UInt64) {
        guard let dragSession else { return }
        dragSession.cancelTimers()

        if let hoverTarget = dragSession.hoverTarget, let targetItem = hoverTarget.itemLayer.item {
            switch targetItem {
            case .application(let targetApplication):
                applyEdit(.makeFolder(merging: dragSession.item.identifier, with: targetApplication.identifier, title: defaultFolderName(for: targetApplication)))
            case .folder(let folder):
                applyEdit(.moveIntoFolder(dragSession.item.identifier, folder: folder.identifier))
            }
            let targetIconRect = hoverTarget.itemLayer.convert(hoverTarget.itemLayer.iconFrame, to: containerLayer)
            animateDraggedLayer(intoIconAt: targetIconRect) { [weak self] in
                hoverTarget.itemLayer.isDropTarget = false
                self?.finishDrag()
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
            guard let folderPanel, folderPanel.folder.pages.indices.contains(dragSession.pageIndex) else { return nil }
            return .move(itemIdentifier, toIndex: dragSession.currentIndex, onPage: folderPanel.folder.pages[dragSession.pageIndex].identifier)
        }
    }

    /// 15 named a new folder after the target application's category, or "Untitled".
    private func defaultFolderName(for application: LaunchpadApplication) -> String {
        if
            let bundleURL = application.bundleURL,
            let categoryIdentifier = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
            let categoryDescription = UTType(categoryIdentifier)?.localizedDescription
        {
            return categoryDescription
        }
        return Bundle.main.localizedString(forKey: "Untitled", value: "Untitled", table: nil)
    }

    private func animateDraggedLayer(intoIconAt targetIconRect: CGRect, completion: @escaping @MainActor () -> Void) {
        guard let dragSession else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                dragSession.itemLayer.removeFromSuperlayer()
                completion()
            }
        }
        dragSession.itemLayer.position = CGPoint(x: targetIconRect.midX, y: targetIconRect.midY)
        dragSession.itemLayer.transform = CATransform3DMakeScale(0.3, 0.3, 1)
        dragSession.itemLayer.opacity = 0
        CATransaction.commit()
    }

    /// Escape, or a drop that changed nothing: everything slides back where it was.
    func cancelDrag() {
        guard let dragSession else { return }
        dragSession.cancelTimers()
        endHover()
        if folderPanel != nil, dragSession.sourceContext == .main {
            closeFolder(animated: false)
        }
        if dragSession.sourceContext == .folder, folderPanel == nil {
            // Dragged out of a folder that has closed since: back into the folder's icon, as 15 did.
            showMainPages(pageIndex: mainPages.currentPageIndex)
            let folderIconLayer = mainPages.itemLayers.first { itemLayer in
                guard case .folder(let folder) = itemLayer.item else { return false }
                return folder.applications.contains { $0.identifier == dragSession.item.identifier }
            }
            guard let folderIconLayer else {
                dragSession.itemLayer.removeFromSuperlayer()
                finishDrag()
                return
            }
            animateDraggedLayer(intoIconAt: folderIconLayer.convert(folderIconLayer.iconFrame, to: containerLayer)) { [weak self] in
                self?.finishDrag()
            }
            return
        }
        // Rebuild the pages the drag started on from the stored layout, then send the icon home.
        let sourcePages = pages(for: dragSession.sourceContext)
        if dragSession.sourceContext == .main {
            showMainPages(pageIndex: dragSession.sourcePageIndex)
        } else if let folderPanel {
            folderPanel.reloadPages(pageIndex: dragSession.sourcePageIndex) { [weak self] itemLayer in
                self?.putIcons(in: itemLayer)
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

    private func finishDrag() {
        dragSession?.cancelTimers()
        dragSession = nil
        applyPendingLayoutIfIdle()
    }
}
