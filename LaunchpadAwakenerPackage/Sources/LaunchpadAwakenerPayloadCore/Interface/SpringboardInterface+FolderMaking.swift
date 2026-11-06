import CoreGraphics
import Foundation
import QuartzCore

extension LaunchpadItemIdentifier {
    /// A folder on screen that is not stored yet — one made by dropping an icon on an application — and
    /// its page. The store's identifiers are all positive.
    static let unsavedFolder = LaunchpadItemIdentifier(rowIdentifier: -1)
    static let unsavedFolderPage = LaunchpadItemIdentifier(rowIdentifier: -2)
}

extension LaunchpadFolder {
    /// A folder of `applications` that exists only on screen until the drop stores it.
    static func unsaved(title: String, applications: [LaunchpadApplication]) -> LaunchpadFolder {
        LaunchpadFolder(
            identifier: .unsavedFolder,
            title: title,
            pages: [LaunchpadFolderPage(identifier: .unsavedFolderPage, applications: applications)]
        )
    }

    var isUnsaved: Bool {
        identifier == .unsavedFolder
    }

    /// The folder with `application` added the way the store adds a dropped one: at the end of the last
    /// page, or on a new page when that one is full.
    package func appending(_ application: LaunchpadApplication, itemsPerPage: Int) -> LaunchpadFolder {
        var newPages = pages
        if let lastPage = newPages.last, lastPage.applications.count < itemsPerPage {
            newPages[newPages.count - 1] = LaunchpadFolderPage(identifier: lastPage.identifier, applications: lastPage.applications + [application])
        } else {
            newPages.append(LaunchpadFolderPage(identifier: .unsavedFolderPage, applications: [application]))
        }
        return LaunchpadFolder(identifier: identifier, title: title, pages: newPages)
    }

    /// The folder without the application `applicationIdentifier`, and without a page that leaves empty.
    package func removing(_ applicationIdentifier: LaunchpadItemIdentifier) -> LaunchpadFolder {
        LaunchpadFolder(
            identifier: identifier,
            title: title,
            pages: pages.compactMap { page in
                let remainingApplications = page.applications.filter { $0.identifier != applicationIdentifier }
                return remainingApplications.isEmpty ? nil : LaunchpadFolderPage(identifier: page.identifier, applications: remainingApplications)
            }
        )
    }
}

/// Making a folder by dragging, and the end of one, as macOS 15 animated them. Section 4.11 of the 15.5
/// notes on folders and dragging gives the frame-by-frame account the comments refer to.
extension SpringboardInterface {
    // MARK: - Dropping onto an application

    /// A release over an application before its folder opened (4.11.1; 15.5
    /// `-[ECSBOpenGroupDragState endDrag:withEvent:]`, `0x100085E04`). At once the preview square goes and
    /// the application turns into a folder of the two, under the target's name for it; the two images
    /// shrink into its first two thumbnails, the dropped one 0.1 s later; 0.75 s after the release the new
    /// folder opens. The dragged icon's cell stays empty until that folder closes.
    func dropIntoNewFolder(around targetApplication: LaunchpadApplication, targetLayer: SpringboardItemLayer, title: String) {
        guard let dragSession, case .application(let draggedApplication) = dragSession.item else {
            finishDrag()
            return
        }
        let unsavedFolder = LaunchpadFolder.unsaved(title: title, applications: [targetApplication, draggedApplication])
        let targetFlight = SpringboardIconFlight.makeFlyingLayer(copying: targetLayer.imageLayer, in: targetLayer)
        let draggedFlight = SpringboardIconFlight.makeFlyingLayer(copying: dragSession.itemLayer.imageLayer, in: targetLayer)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        targetLayer.isDropTarget = false
        // In jiggle mode 15's new folder shook at once.
        targetLayer.isHeldStill = false
        dragSession.itemLayer.removeFromSuperlayer()
        turnIntoFolderIcon(targetLayer, showing: unsavedFolder)
        targetLayer.setThumbnailOpacity(0, forSlots: 0..<2)
        targetLayer.addSublayer(targetFlight)
        targetLayer.addSublayer(draggedFlight)
        CATransaction.commit()
        // The images must be on screen where they start before they fly.
        CATransaction.flush()

        SpringboardIconFlight.fly(targetFlight, intoThumbnailAt: 0, of: targetLayer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                SpringboardIconFlight.fly(draggedFlight, intoThumbnailAt: 1, of: targetLayer)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dragSession === dragSession, self.containerLayer.superlayer != nil else { return }
                self.mainPagePlaceholder = (dragSession.pageIndex, dragSession.arrangedLayers)
                self.finishDrag()
                let storedFolder = self.pendingLayout.flatMap { self.storedFolder(for: unsavedFolder, in: $0) }
                self.openFolder(storedFolder ?? unsavedFolder, from: targetLayer)
                if self.folderPanel == nil {
                    // It could not open; there is nothing to wait for, so the gap closes now.
                    self.closeMainPagePlaceholderNow()
                }
            }
        }
    }

    // MARK: - Dropping onto a folder

    /// A release over a folder before it opened (4.11.2). The dragged image shrinks into the thumbnail of
    /// the last application on the folder's first page — the new one, unless the folder has more pages —
    /// while the folder's square shrinks back and its title fades in, and the other icons close the gap at
    /// once. The thumbnails stay scrolled to the free slot; the folder does not open.
    func dropIntoFolder(_ folder: LaunchpadFolder, folderItemLayer: SpringboardItemLayer) {
        guard let dragSession, case .application(let draggedApplication) = dragSession.item else {
            finishDrag()
            return
        }
        let updatedFolder = folder.appending(draggedApplication, itemsPerPage: SpringboardPreferences.itemsPerPage)
        let firstPageApplications = updatedFolder.pages.first?.applications ?? []
        let slot = max(firstPageApplications.count - 1, 0)
        let isNewThumbnail = firstPageApplications.last?.identifier == draggedApplication.identifier
        let flight = SpringboardIconFlight.makeFlyingLayer(copying: dragSession.itemLayer.imageLayer, in: folderItemLayer)

        folderItemLayer.endDropTargetAfterDrop()
        folderItemLayer.isHeldStill = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dragSession.itemLayer.removeFromSuperlayer()
        folderItemLayer.configure(with: .folder(updatedFolder), metrics: metrics, scale: scale)
        putIcons(in: folderItemLayer)
        folderItemLayer.layoutIfNeeded()
        if isNewThumbnail {
            folderItemLayer.setThumbnailOpacity(0, forSlots: slot..<(slot + 1))
        }
        folderItemLayer.addSublayer(flight)
        CATransaction.commit()
        CATransaction.flush()

        if dragSession.arrangedLayers.indices.contains(dragSession.currentIndex) {
            dragSession.arrangement.remove(at: dragSession.currentIndex)
            dragSession.arrangedLayers.remove(at: dragSession.currentIndex)
            dragSession.currentIndex = dragSession.arrangement.count
        }
        animateArrangement(duration: SpringboardIconFlight.duration)
        SpringboardIconFlight.fly(flight, intoThumbnailAt: slot, of: folderItemLayer) { [weak self] in
            // Once the thumbnail is in, the grid scrolls again for the new count.
            CATransaction.begin()
            CATransaction.setAnimationDuration(SpringboardIconFlight.duration)
            folderItemLayer.scrollThumbnails(toAvailableSpace: true)
            CATransaction.commit()
            self?.finishDrag()
        }
    }

    // MARK: - Holding over an application

    /// Held over an application for a second (4.11.3; 15.5 `_beginNewGroupTransition`, `0x100085060`).
    /// The preview square and the application's icon go, and a folder of just that application opens out
    /// of its cell under the dragged icon, which grows back to 1.1 times. Once it is open the dragged icon
    /// takes the second cell. Nothing is stored until the release; leaving the folder dissolves it.
    func springLoadNewFolder(around targetApplication: LaunchpadApplication, targetLayer: SpringboardItemLayer) {
        guard let dragSession, !dragSession.isEnding, folderPanel == nil, !isAnimatingFolder, case .application = dragSession.item else { return }
        let title = defaultFolderName(for: targetApplication)
        let unsavedFolder = LaunchpadFolder.unsaved(title: title, applications: [targetApplication])
        endHover()
        cancelEdgePageTurn()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        turnIntoFolderIcon(targetLayer, showing: unsavedFolder)
        CATransaction.commit()
        dragSession.mainPageArrangement = (dragSession.pageIndex, dragSession.arrangedLayers)
        dragSession.unsavedFolderTarget = (targetApplication, title)
        openFolder(unsavedFolder, from: targetLayer) { [weak self] in
            self?.carryDraggedItemIntoOpenFolder()
        }
        keepDraggedIconOnTop()
    }

    /// Makes an application's cell show `folder` instead, beneath the page's other icons as 15 inserted a
    /// new folder (`-[ECSBGridLayer insertItemLayer:atIndex:]`, 15.5 `0x10011E370`).
    private func turnIntoFolderIcon(_ itemLayer: SpringboardItemLayer, showing folder: LaunchpadFolder) {
        itemLayer.configure(with: .folder(folder), metrics: metrics, scale: scale)
        putIcons(in: itemLayer)
        itemLayer.layoutIfNeeded()
        itemLayer.superlayer?.insertSublayer(itemLayer, at: 0)
    }

    // MARK: - Dissolving

    /// A folder left with one application or none, 250 ms after it closed (15.5
    /// `CloseGroupDragState_dissolveAnimationBlock`, `0x100120500`): the application grows out of the
    /// first thumbnail into the folder's cell and its title fades in, while the folder's square shrinks to
    /// a tenth and fades out. Default animations; the cell is the application's afterwards.
    func dissolveFolderIcon(_ folderItemLayer: SpringboardItemLayer, into remainingApplication: LaunchpadApplication?) {
        guard let superlayer = folderItemLayer.superlayer else { return }
        var applicationLayer: SpringboardItemLayer?
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let remainingApplication, let thumbnailRect = folderItemLayer.thumbnailFrame(atSlot: 0), folderItemLayer.bounds.width > 0 {
            let growingLayer = SpringboardItemLayer()
            growingLayer.configure(with: .application(remainingApplication), metrics: metrics, scale: scale)
            putIcons(in: growingLayer)
            growingLayer.frame = folderItemLayer.frame
            growingLayer.layoutIfNeeded()
            let thumbnailInSuperlayer = folderItemLayer.convert(thumbnailRect, to: superlayer)
            let thumbnailScale = thumbnailRect.width / folderItemLayer.bounds.width
            growingLayer.transform = CATransform3DMakeScale(thumbnailScale, thumbnailScale, 1)
            growingLayer.position = CGPoint(x: thumbnailInSuperlayer.midX + 1, y: thumbnailInSuperlayer.midY - 1)
            growingLayer.labelLayer.opacity = 0
            superlayer.addSublayer(growingLayer)
            applicationLayer = growingLayer
        }
        CATransaction.commit()
        CATransaction.flush()

        let cellPosition = folderItemLayer.position
        CATransaction.begin()
        CATransaction.setAnimationDuration(SpringboardFolderPanel.animationDuration)
        applicationLayer?.transform = CATransform3DIdentity
        applicationLayer?.position = cellPosition
        applicationLayer?.labelLayer.opacity = 1
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(SpringboardFolderPanel.animationDuration)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                applicationLayer?.removeFromSuperlayer()
                if let self, let remainingApplication {
                    folderItemLayer.configure(with: .application(remainingApplication), metrics: self.metrics, scale: self.scale)
                    self.putIcons(in: folderItemLayer)
                    folderItemLayer.transform = CATransform3DIdentity
                    folderItemLayer.opacity = 1
                } else {
                    folderItemLayer.removeFromSuperlayer()
                }
                CATransaction.commit()
            }
        }
        folderItemLayer.opacity = 0
        folderItemLayer.transform = CATransform3DMakeScale(0.1, 0.1, 1)
        CATransaction.commit()
    }
}
