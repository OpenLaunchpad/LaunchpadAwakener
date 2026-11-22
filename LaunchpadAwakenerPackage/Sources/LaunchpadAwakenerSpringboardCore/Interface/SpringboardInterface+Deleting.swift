import CoreGraphics
import Foundation
import QuartzCore

/// The question asked before deleting an application, from the release on its close box until it is
/// answered. While it is asked it takes every click and key.
@MainActor
final class SpringboardDeletionQuestion {
    enum Presentation {
        /// Another process is asked to show its popover, or shows it.
        case hosted(any SpringboardHostedDeletionConfirmation)
        /// Drawn in the springboard, where no other process shows the popover.
        case drawn(SpringboardDeletionPanel)
    }

    let application: LaunchpadApplication
    let context: SpringboardInterface.GridContext
    weak var itemLayer: SpringboardItemLayer?
    /// Nil only until the question is put.
    var presentation: Presentation?

    init(application: LaunchpadApplication, context: SpringboardInterface.GridContext, itemLayer: SpringboardItemLayer) {
        self.application = application
        self.context = context
        self.itemLayer = itemLayer
    }
}

/// Deleting an application from jiggle mode, as macOS 15's Launchpad did for applications the Dock's
/// uninstaller takes — in practice those from the App Store.
extension SpringboardInterface {
    /// Tells an icon about to jiggle whether it gets a close box.
    func prepareCloseBox(for itemLayer: SpringboardItemLayer) {
        guard case .application(let application) = itemLayer.item else {
            itemLayer.isDeletable = false
            return
        }
        itemLayer.isDeletable = canDelete(application)
    }

    /// Whether the Dock's uninstaller takes the application, asked once per application and showing.
    func canDelete(_ application: LaunchpadApplication) -> Bool {
        guard let bundleURL = application.bundleURL else { return false }
        if let isDeletable = deletabilityByBundlePath[bundleURL.path] {
            return isDeletable
        }
        let isDeletable = resolveApplicationUninstaller()?.canUninstall(applicationAt: bundleURL) ?? false
        deletabilityByBundlePath[bundleURL.path] = isDeletable
        return isDeletable
    }

    /// Asks whether to delete the application whose close box was let go on: 15's popover under the
    /// icon (`-[ECSBPager presentDeletionPanelForItem:withEvent:]`, 15.5 `0x100059A8C`), shown by another
    /// process as the Dock's ecap service showed it, or drawn here where none can show it. One question at
    /// a time, as in 15.
    func presentDeletionPanel(for itemLayer: SpringboardItemLayer, context: GridContext) {
        guard deletionQuestion == nil, case .application(let application) = itemLayer.item else { return }
        let question = SpringboardDeletionQuestion(application: application, context: context, itemLayer: itemLayer)
        deletionQuestion = question
        guard let confirmation = hostedDeletionConfirmation(for: application, itemLayer: itemLayer) else {
            drawDeletionPanel(for: question)
            return
        }
        question.presentation = .hosted(confirmation)
        confirmation.answerHandler = { [weak self, weak question] choice in
            guard let self, let question, deletionQuestion === question else { return }
            answerDeletionPanel(choice)
        }
        confirmation.presentationDidFail = { [weak self, weak question] in
            guard let self, let question, deletionQuestion === question else { return }
            drawDeletionPanel(for: question)
        }
        // The popover went with the process showing it: nothing is asked any more.
        confirmation.interruptionHandler = { [weak self, weak question] in
            guard let self, let question, deletionQuestion === question else { return }
            answerDeletionPanel(.cancel)
        }
        confirmation.present()
    }

    /// The popover for the question, hanging from the icon's centre; nil where no other process shows it,
    /// or where the springboard does not know where it is on screen.
    private func hostedDeletionConfirmation(for application: LaunchpadApplication, itemLayer: SpringboardItemLayer) -> (any SpringboardHostedDeletionConfirmation)? {
        guard let screenTopLeft, let bundleURL = application.bundleURL else { return nil }
        let imageLayer = itemLayer.imageLayer
        let iconFrame = imageLayer.convert(imageLayer.bounds, to: containerLayer)
        let screenIconCenter = screenTopLeft(CGRect(x: iconFrame.midX, y: iconFrame.midY, width: 0, height: 0))
        return makeHostedDeletionConfirmation(SpringboardHostedDeletionConfirmationConfiguration(
            icon: Self.image(fromContents: imageLayer.contents),
            bundleURL: bundleURL,
            message: SpringboardDeletionStrings.message(forApplicationNamed: application.title),
            cancelButtonTitle: SpringboardDeletionStrings.cancel,
            deleteButtonTitle: SpringboardDeletionStrings.delete,
            screenIconCenter: screenIconCenter
        ))
    }

    /// Draws the question here: no other process shows the popover, or the one asked could not.
    private func drawDeletionPanel(for question: SpringboardDeletionQuestion) {
        guard let itemLayer = question.itemLayer else {
            answerDeletionPanel(.cancel)
            return
        }
        let imageLayer = itemLayer.imageLayer
        let iconCenter = imageLayer.convert(CGPoint(x: imageLayer.bounds.midX, y: imageLayer.bounds.midY), to: containerLayer)
        let panel = SpringboardDeletionPanel(
            applicationTitle: question.application.title,
            iconContents: imageLayer.contents,
            layout: SpringboardDeletionPanel.Layout(iconCenter: iconCenter, containerBounds: containerLayer.bounds),
            scale: scale
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.addSublayer(panel)
        CATransaction.commit()
        question.presentation = .drawn(panel)
    }

    /// A press while the question is asked: the drawn panel's buttons answer it, and anywhere else nothing
    /// happens, as the Dock's transparent backdrop swallowed such clicks. Presses on a hosted popover never
    /// come here.
    func pressWhileAskingToDelete(at containerPoint: CGPoint) {
        guard
            let deletionQuestion,
            case .drawn(let panel) = deletionQuestion.presentation,
            let choice = panel.choice(at: panel.convert(containerPoint, from: containerLayer))
        else { return }
        answerDeletionPanel(choice)
    }

    /// Ends the question, if one is asked: the popover or the panel goes, and an application confirmed for
    /// deletion is deleted. 15's Dock closed the popover itself for either button, for the keys and when
    /// Launchpad went (`-[ECAlertPanel dismissWithClickedButtonIndex:]`, 15.5 `0x10007AF30`).
    func answerDeletionPanel(_ choice: SpringboardDeletionChoice) {
        guard let question = deletionQuestion else { return }
        deletionQuestion = nil
        switch question.presentation {
        case .hosted(let confirmation):
            confirmation.dismiss()
        case .drawn(let panel):
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.removeFromSuperlayer()
            CATransaction.commit()
        case nil:
            break
        }
        guard choice == .delete, let itemLayer = question.itemLayer else { return }
        delete(question.application, itemLayer: itemLayer, context: question.context)
    }

    /// A layer's contents as an image: `CGImage` is a Core Foundation type, which a cast does not check.
    private static func image(fromContents contents: Any?) -> CGImage? {
        guard let contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage)
    }

    /// 15 played the icon out over half a second, fading to nothing at a tenth of its size, and asked for the
    /// uninstall as it started (`-[Springboard _uninstallRunnable:]`, 15.5 `0x1000976A8`, put the item on a
    /// hidden page and sent the request together; the animation at `0x1000F5A8C`). Once the icon had played
    /// out, the page closed the gap (`sub_1000F5C68`), whatever the uninstall had answered by then.
    private func delete(_ application: LaunchpadApplication, itemLayer: SpringboardItemLayer, context: GridContext) {
        guard let bundleURL = application.bundleURL else { return }
        itemLayer.isBeingDeleted = true
        let deletion = SpringboardDeletion(
            application: application,
            folderIdentifier: context == .folder ? folderPanel?.folder.identifier : nil,
            itemLayer: itemLayer,
            context: context
        )
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                deletion.hasPlayedOut = true
                self?.carryOn(deletion)
            }
        }
        itemLayer.opacity = 0
        itemLayer.transform = CATransform3DMakeScale(0.1, 0.1, 1)
        CATransaction.commit()
        guard let uninstaller = resolveApplicationUninstaller() else {
            deletion.hasSucceeded = false
            carryOn(deletion)
            return
        }
        uninstaller.uninstall(applicationAt: bundleURL) { [weak self] hasSucceeded in
            deletion.hasSucceeded = hasSucceeded
            self?.carryOn(deletion)
        }
    }

    /// Takes a deletion as far as what has happened allows: nothing until the icon has played out; then the
    /// page closes the gap in a quarter of a second, without pulling icons over from the next page, unless
    /// the uninstall has failed already; an uninstall that succeeded drops the application from the layout.
    /// One that fails brings the icon back where it was, the gap opening again — 15 put it in the next free
    /// place instead (`layoutItemsToNextAvailableSpace:`).
    private func carryOn(_ deletion: SpringboardDeletion) {
        guard deletion.hasPlayedOut else { return }
        let pageGrid = pages(for: deletion.context).pageGrids.first { pageGrid in
            pageGrid.itemLayers.contains { $0 === deletion.itemLayer }
        }
        switch deletion.hasSucceeded {
        case false?:
            guard !deletion.isFinished else { return }
            deletion.isFinished = true
            bringBack(deletion, in: pageGrid)
        case true?:
            closeGap(of: deletion, in: pageGrid)
            guard !deletion.isFinished else { return }
            deletion.isFinished = true
            applyEdit(.removeApplication(deletion.application.identifier, folder: deletion.folderIdentifier))
        case nil:
            closeGap(of: deletion, in: pageGrid)
        }
    }

    private func closeGap(of deletion: SpringboardDeletion, in pageGrid: SpringboardPageGrid?) {
        guard !deletion.hasClosedGap, let pageGrid, let deletedIndex = pageGrid.itemLayers.firstIndex(where: { $0 === deletion.itemLayer }) else { return }
        deletion.hasClosedGap = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        for (index, layer) in pageGrid.itemLayers.enumerated() where index > deletedIndex {
            layer.setUntransformedFrame(pageGrid.cellFrame(at: index - 1))
        }
        CATransaction.commit()
    }

    private func bringBack(_ deletion: SpringboardDeletion, in pageGrid: SpringboardPageGrid?) {
        deletion.itemLayer.isBeingDeleted = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        if deletion.hasClosedGap, let pageGrid, let deletedIndex = pageGrid.itemLayers.firstIndex(where: { $0 === deletion.itemLayer }) {
            for (index, layer) in pageGrid.itemLayers.enumerated() where index > deletedIndex {
                layer.setUntransformedFrame(pageGrid.cellFrame(at: index))
            }
        }
        deletion.itemLayer.opacity = 1
        deletion.itemLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}

/// One application on its way out: what has happened to it so far.
@MainActor
final class SpringboardDeletion {
    let application: LaunchpadApplication
    let folderIdentifier: LaunchpadItemIdentifier?
    let itemLayer: SpringboardItemLayer
    let context: SpringboardInterface.GridContext
    /// Whether the icon has finished playing out.
    var hasPlayedOut = false
    /// What the uninstall answered; nil until it has.
    var hasSucceeded: Bool?
    var hasClosedGap = false
    /// Set once the layout has been told, or the icon brought back.
    var isFinished = false

    init(application: LaunchpadApplication, folderIdentifier: LaunchpadItemIdentifier?, itemLayer: SpringboardItemLayer, context: SpringboardInterface.GridContext) {
        self.application = application
        self.folderIdentifier = folderIdentifier
        self.itemLayer = itemLayer
        self.context = context
    }
}
