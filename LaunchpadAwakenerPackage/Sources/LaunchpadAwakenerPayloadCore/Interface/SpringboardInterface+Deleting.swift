import CoreGraphics
import Foundation
import QuartzCore

/// Deleting an application from jiggle mode, as macOS 15's Launchpad did for applications the Dock's
/// uninstaller takes — in practice those from the App Store.
extension SpringboardInterface {
    /// Tells an icon about to jiggle whether it gets a close box, asking the Dock's uninstaller once per
    /// application and showing.
    func prepareCloseBox(for itemLayer: SpringboardItemLayer) {
        guard case .application(let application) = itemLayer.item, let bundleURL = application.bundleURL else {
            itemLayer.isDeletable = false
            return
        }
        if let isDeletable = deletabilityByBundlePath[bundleURL.path] {
            itemLayer.isDeletable = isDeletable
            return
        }
        let isDeletable = DockApplicationUninstaller.canUninstall(applicationAt: bundleURL)
        deletabilityByBundlePath[bundleURL.path] = isDeletable
        itemLayer.isDeletable = isDeletable
    }

    /// Asks whether to delete the application whose close box was let go on: 15's popover under the
    /// icon (`-[ECSBPager presentDeletionPanelForItem:withEvent:]`, 15.5 `0x100059A8C`).
    func presentDeletionPanel(for itemLayer: SpringboardItemLayer, context: GridContext) {
        guard deletionPanel == nil, case .application(let application) = itemLayer.item else { return }
        let imageLayer = itemLayer.imageLayer
        let iconCenter = imageLayer.convert(CGPoint(x: imageLayer.bounds.midX, y: imageLayer.bounds.midY), to: containerLayer)
        let panel = SpringboardDeletionPanel(
            application: application,
            itemLayer: itemLayer,
            context: context,
            layout: SpringboardDeletionPanel.Layout(iconCenter: iconCenter, containerBounds: containerLayer.bounds),
            scale: scale
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.addSublayer(panel)
        CATransaction.commit()
        deletionPanel = panel
    }

    /// A press while the popover shows: its buttons answer it, and anywhere else nothing happens, as
    /// the service's transparent backdrop swallowed such clicks.
    func pressWhileAskingToDelete(at containerPoint: CGPoint) {
        guard let deletionPanel, let choice = deletionPanel.choice(at: deletionPanel.convert(containerPoint, from: containerLayer)) else { return }
        answerDeletionPanel(choice)
    }

    func answerDeletionPanel(_ choice: SpringboardDeletionPanel.Choice) {
        guard let panel = deletionPanel else { return }
        deletionPanel = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.removeFromSuperlayer()
        CATransaction.commit()
        guard choice == .delete, let target = panel.target, let itemLayer = target.itemLayer else { return }
        delete(target.application, itemLayer: itemLayer, context: target.context)
    }

    /// 15 played the icon out over half a second, fading to nothing at a tenth of its size, then deleted
    /// the application (`-[Springboard _uninstallRunnable:]`, the animation at 15.5 `0x1000F5A8C`).
    private func delete(_ application: LaunchpadApplication, itemLayer: SpringboardItemLayer, context: GridContext) {
        guard let bundleURL = application.bundleURL else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                DockApplicationUninstaller.uninstall(applicationAt: bundleURL) { [weak self] hasSucceeded in
                    self?.finishDeleting(application, itemLayer: itemLayer, context: context, hasSucceeded: hasSucceeded)
                }
            }
        }
        itemLayer.opacity = 0
        itemLayer.transform = CATransform3DMakeScale(0.1, 0.1, 1)
        CATransaction.commit()
    }

    /// Once deleted, the page closes the gap in a quarter of a second without pulling icons over from the
    /// next page, and the layout drops the application. A failed delete brings the icon back where it was;
    /// 15 put it in the next free place instead.
    private func finishDeleting(_ application: LaunchpadApplication, itemLayer: SpringboardItemLayer, context: GridContext, hasSucceeded: Bool) {
        guard hasSucceeded else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            itemLayer.opacity = 1
            itemLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            return
        }
        if let pageGrid = pages(for: context).currentPageGrid, let deletedIndex = pageGrid.itemLayers.firstIndex(where: { $0 === itemLayer }) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            for (index, layer) in pageGrid.itemLayers.enumerated() where index > deletedIndex {
                layer.setUntransformedFrame(pageGrid.cellFrame(at: index - 1))
            }
            CATransaction.commit()
        }
        applyEdit(.removeApplication(application.identifier))
    }
}
