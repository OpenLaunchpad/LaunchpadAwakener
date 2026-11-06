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

    /// Set once the icon is let go: the drop is animating, and input waits until it ends.
    var isEnding = false
    /// A release that came while a folder was opening or closing; carried out once it has.
    var pendingDrop: (location: CGPoint, timestamp: UInt64)?
    /// Set from leaving a folder until its icon is back on the main page, 250 ms after it closed.
    var isWaitingForFolderToClose = false

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
        guard let dragSession, !dragSession.isEnding, !dragSession.isWaitingForFolderToClose, !isAnimatingFolder else { return }
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
        dragSession.context = .folder
        dragSession.pageIndex = folderPanel.pages.currentPageIndex
        dragSession.arrangement = currentPage.items + [dragSession.item]
        dragSession.arrangedLayers = currentPage.itemLayers.map(Optional.some) + [nil]
        dragSession.currentIndex = dragSession.arrangement.count - 1
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
        // The main page as the drag left it when the folder opened, if it did; its gap is dropped below.
        let mainPageArrangement = dragSession.mainPageArrangement
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
        guard let dragSession, !dragSession.isEnding else { return }
        // A release while a folder opens or closes waits for it to finish, as 15's did.
        if isAnimatingFolder || dragSession.isWaitingForFolderToClose {
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
        dragSession.isEnding = true
        dragSession.cancelTimers()
        dragSession.mainPageArrangement = nil
        dragSession.unsavedFolderTarget = nil
        endHover()
        var closingFolder: LaunchpadFolder?
        if let folderPanel, dragSession.sourceContext == .main {
            closingFolder = folderPanel.folder
            if isAnimatingFolder {
                dismissFolderImmediately()
            } else {
                closeFolder()
            }
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
            slideDraggedLayer(intoFolderIcon: folderIconLayer) { [weak self] in
                self?.finishDrag()
            }
            return
        }
        // Rebuild the pages the drag started on from the stored layout, then send the icon home.
        let sourcePages = pages(for: dragSession.sourceContext)
        if dragSession.sourceContext == .main {
            showMainPages(pageIndex: dragSession.sourcePageIndex)
            if let closingFolder, folderPanel != nil {
                // The closing panel shrinks onto the rebuilt page's icon of its folder, shown once it has.
                hideFolderIcon(of: closingFolder)
            }
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
        dragSession?.cancelTimers()
        dragSession = nil
        applyPendingLayoutIfIdle()
    }
}
