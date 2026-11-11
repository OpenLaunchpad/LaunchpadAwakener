import CoreGraphics
import Foundation
import QuartzCore

/// Dragging an icon onto the Dock, as macOS 15's Launchpad let one be dragged there
/// (`-[Springboard didDragItem:withEvent:andLayer:]`, 15.5 `0x1000936BC`, and
/// `didEndDragOfItem:withEvent:andLayer:`, `0x100093AD4`).
///
/// On the Dock the icon dims to half and the Dock opens a gap for an application, as for one dragged in
/// from the Finder. Meanwhile nothing in the springboard responds to where the icon is: no room is made,
/// no folder opens, no page turns. Let go there, the Dock keeps the application in the gap and the
/// springboard puts the icon back in its place at once, without sliding (`cancelDrag:0` from
/// `-[ECSBDragCapture leftMouseUp:in:]`, `0x1000B65B0`); let go on the Trash, the springboard asks to delete
/// the application if it can be deleted (`-[ECSBSpringboard confirmRemoveItem:]`, `0x1000F5FF0`).
///
/// The Dock's windows sit above the springboard's, so on the Dock the icon rides in a transparent window
/// above them, laid out like ``containerLayer``: 15 carried every dragged icon in such a window. Only while
/// it is on the Dock, though — the rest of the drag converts the icon's geometry into the pages', which
/// works only while both are in the same layer tree.
extension SpringboardInterface {
    /// Follows the pointer onto and off the Dock; returns whether it is on the Dock now.
    func trackDock(at containerPoint: CGPoint) -> Bool {
        guard
            let dragSession,
            dragSession.dockDropResult == nil,
            let dockDropTarget = dragSession.dockDropTarget,
            let screenTopLeft
        else { return false }
        let globalPoint = screenTopLeft(CGRect(origin: containerPoint, size: .zero))
        let isOnDock = dockDropTarget.contains(globalPoint)
        switch (dragSession.isOverDock, isOnDock) {
        case (false, true):
            enterDock(dockDropTarget, at: globalPoint)
        case (true, true):
            dragSession.dockDrag?.move(to: globalPoint)
        case (true, false):
            leaveDock()
        case (false, false):
            break
        }
        return isOnDock
    }

    /// The pointer came onto the Dock: the springboard stops responding, the icon rides above the Dock at
    /// half its opacity, as 15 dimmed it, and an application is handed to the Dock.
    private func enterDock(_ dockDropTarget: any SpringboardDockDropTarget, at globalPoint: CGPoint) {
        guard let dragSession else { return }
        dragSession.isOverDock = true
        dragSession.cancelTimers()
        endHover()
        carryDraggedIconAboveDock(dockDropTarget)
        dragSession.itemLayer.opacity = 0.5
        if case .application(let application) = dragSession.item, let bundleURL = application.bundleURL {
            dragSession.dockDrag = dockDropTarget.beginDrag(ofApplicationAt: bundleURL, at: globalPoint)
        }
    }

    /// The pointer left the Dock, or the drag is cancelled: the Dock closes its gap, and the icon is back
    /// in the springboard at full opacity.
    func leaveDock() {
        guard let dragSession, dragSession.isOverDock else { return }
        dragSession.isOverDock = false
        dragSession.dockDrag?.cancel()
        dragSession.dockDrag = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if dragSession.itemLayer.superlayer === dragSession.dragWindow?.containerLayer {
            containerLayer.addSublayer(dragSession.itemLayer)
        }
        CATransaction.commit()
        dragSession.itemLayer.opacity = 1
    }

    /// Moves the dragged icon into the window above the Dock, making that window the first time. The
    /// window's layer is laid out like ``containerLayer``, so the icon keeps its frame.
    private func carryDraggedIconAboveDock(_ dockDropTarget: any SpringboardDockDropTarget) {
        guard let dragSession else { return }
        if dragSession.dragWindow == nil, let window = dockDropTarget.makeDragWindow() {
            let windowContainerLayer = CALayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            windowContainerLayer.frame = containerLayer.frame
            windowContainerLayer.isGeometryFlipped = window.rootLayer.contentsAreFlipped()
            window.rootLayer.addSublayer(windowContainerLayer)
            CATransaction.commit()
            window.orderIn()
            dragSession.dragWindow = (window, windowContainerLayer)
        }
        guard let windowContainerLayer = dragSession.dragWindow?.containerLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        windowContainerLayer.addSublayer(dragSession.itemLayer)
        CATransaction.commit()
    }

    /// Lets go of the icon on the Dock: the Dock keeps an application where its gap was, or the release
    /// fell on the Trash. The springboard puts the icon back once nothing else holds the drop up.
    func dropOnDock(at containerPoint: CGPoint) {
        guard let dragSession, dragSession.isOverDock else { return }
        var result = SpringboardDockDropResult.none
        if let dockDrag = dragSession.dockDrag, let screenTopLeft {
            result = dockDrag.drop(at: screenTopLeft(CGRect(origin: containerPoint, size: .zero)))
        }
        dragSession.dockDrag = nil
        dragSession.dockDropResult = result
    }

    /// After a release on the Dock: the icon is back in its place at once, and a release on the Trash asks
    /// to delete the application, if it can be deleted, from that place.
    ///
    /// The place is looked for in the open folder, then on the main pages: putting the icon back may have
    /// started closing a folder the drag held open, which stays on screen while it closes. An application
    /// back inside a closed folder has no icon of its own to ask from, and is not asked about. The page was
    /// just rebuilt, so its icon is laid out before the popover is placed by it.
    func finishDropOnDock(_ result: SpringboardDockDropResult) {
        guard let dragSession else { return }
        let draggedItem = dragSession.item
        cancelDrag(slidingBack: false)
        guard result == .trash, case .application(let application) = draggedItem, canDelete(application) else { return }
        let contexts: [GridContext] = folderPanel == nil ? [.main] : [.folder, .main]
        for context in contexts {
            guard let itemLayer = pages(for: context).itemLayers.first(where: { $0.item?.identifier == application.identifier }) else { continue }
            itemLayer.layoutIfNeeded()
            presentDeletionPanel(for: itemLayer, context: context)
            return
        }
    }
}
