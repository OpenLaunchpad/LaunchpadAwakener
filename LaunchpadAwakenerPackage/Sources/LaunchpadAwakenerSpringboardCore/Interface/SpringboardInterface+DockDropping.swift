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
/// The Dock's windows sit above the springboard's, so the dragged icon rides in a transparent window above
/// them for the whole drag, as 15 carried every dragged icon in a window at the dragging level
/// (`-[ECSBDragCapture _beginDragOfItemLayerWithEvent:itemFrame:]`, 15.5 `0x1000B4B98`): an icon that is
/// partly over the Dock would otherwise slip under it. That window's layer is laid out like
/// ``containerLayer`` but is a layer tree of its own, so the icon's geometry reaches the pages through
/// ``rectInContainer(_:of:)``.
extension SpringboardInterface {
    // MARK: - Above the Dock

    /// Moves the icon just picked up into a window above the Dock, where the host offers one, for the rest
    /// of the drag. The window's layer is laid out like ``containerLayer``, so the icon keeps its frame.
    func carryDraggedIconAboveDock() {
        guard
            let dragSession,
            dragSession.dragWindow == nil,
            let window = dragSession.dockDropTarget?.makeDragWindow()
        else { return }
        let windowContainerLayer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        windowContainerLayer.frame = containerLayer.frame
        windowContainerLayer.isGeometryFlipped = window.rootLayer.contentsAreFlipped()
        window.rootLayer.addSublayer(windowContainerLayer)
        windowContainerLayer.addSublayer(dragSession.itemLayer)
        CATransaction.commit()
        window.orderIn()
        dragSession.dragWindow = (window, windowContainerLayer)
    }

    /// Brings an icon still above the Dock back under the springboard, keeping its frame: as the
    /// springboard goes, the icon goes with everything else rather than staying in sight above it.
    func bringDraggedIconIntoSpringboard() {
        guard
            let dragSession,
            let windowContainerLayer = dragSession.dragWindow?.containerLayer,
            dragSession.itemLayer.superlayer === windowContainerLayer
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.addSublayer(dragSession.itemLayer)
        CATransaction.commit()
    }

    /// `rect` of `layer` — the dragged icon or a layer inside it — in ``containerLayer``'s coordinates,
    /// wherever the icon is. The window above the Dock is laid out like the container, but `convert(_:to:)`
    /// does not promise to reach from one layer tree into another.
    func rectInContainer(_ rect: CGRect, of layer: CALayer) -> CGRect {
        if let windowContainerLayer = dragSession?.dragWindow?.containerLayer, dragSession?.itemLayer.superlayer === windowContainerLayer {
            return layer.convert(rect, to: windowContainerLayer)
        }
        return layer.convert(rect, to: containerLayer)
    }

    // MARK: - On the Dock

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

    /// The pointer came onto the Dock: the springboard stops responding, the icon dims to half, as 15
    /// dimmed it, and an application is handed to the Dock.
    private func enterDock(_ dockDropTarget: any SpringboardDockDropTarget, at globalPoint: CGPoint) {
        guard let dragSession else { return }
        dragSession.isOverDock = true
        dragSession.cancelTimers()
        endHover()
        dragSession.itemLayer.opacity = 0.5
        if case .application(let application) = dragSession.item, let bundleURL = application.bundleURL {
            dragSession.dockDrag = dockDropTarget.beginDrag(ofApplicationAt: bundleURL, at: globalPoint)
        }
    }

    /// The pointer left the Dock, or the drag is ending: the Dock closes its gap, and the icon is back at
    /// full opacity — over the usual quarter of a second while it is still dragged, at once when the drag
    /// ends, so that it does not brighten while everything else fades out.
    func leaveDock(animated: Bool = true) {
        guard let dragSession, dragSession.isOverDock else { return }
        dragSession.isOverDock = false
        dragSession.dockDrag?.cancel()
        dragSession.dockDrag = nil
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        dragSession.itemLayer.opacity = 1
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
