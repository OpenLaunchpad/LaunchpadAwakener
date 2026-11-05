import CoreGraphics
import Foundation
import ObjectiveC
import OSToolbox
import QuartzCore

/// The main interface — pages, page dots, search, folders — and what input does to it; macOS 15's
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

    /// Where a press happened: the main pages, or the open folder's.
    enum GridContext {
        case main
        case folder
    }

    /// How long the typed search waits for the next key before searching (`-[ECSBLayer observeValueForKeyPath:…]`).
    private static let searchDelay: Duration = .milliseconds(150)

    let containerLayer = CALayer()
    private(set) var layout: LaunchpadLayout
    let metrics: SpringboardMetrics
    let scale: CGFloat
    /// Stores an edit; the new layout comes back through ``replaceLayout(_:)``.
    let applyEdit: (LaunchpadEdit) -> Void
    let springboardLayer = CALayer()
    /// 15's `_desktopContainerLayer`: the wallpaper, filtered and rasterized once.
    private let desktopContainerLayer = CALayer()
    let mainPages: SpringboardPagedGrids
    private let searchFieldLayer = SpringboardSearchFieldLayer()
    private let noResultsLayer = SpringboardNoResultsLayer()

    private var pageIndexBeforeSearch = 0
    private var selectedItemIndex: Int?
    private var searchText = ""
    private(set) var isShowingSearchResults = false
    private var searchTask: Task<Void, Never>?

    private(set) var folderPanel: SpringboardFolderPanel?
    /// True while a folder opens or closes; input and layout changes wait.
    private(set) var isAnimatingFolder = false
    private var renamingTitle: String?
    private var pendingLayout: LaunchpadLayout?

    private enum PointerTracking {
        case none
        case icon(context: GridContext, pageIndex: Int, itemIndex: Int, itemLayer: SpringboardItemLayer, startLocation: CGPoint, startTimestamp: UInt64)
        case background(context: GridContext, startLocation: CGPoint, startScrollValue: CGFloat, startTimestamp: UInt64, isDragging: Bool)
        case pagerIndicator(context: GridContext, pageIndex: Int)
        case clearButton
        case searchField
        case folderTitle
    }

    private var pointerTracking: PointerTracking = .none
    /// Set while an icon is being dragged; see `SpringboardInterface+Dragging.swift`.
    var dragSession: SpringboardDragSession?

    /// - Parameter desktopImage: The wallpaper as captured on opening; nil falls back to 15's own gradient.
    init(
        layout: LaunchpadLayout,
        metrics: SpringboardMetrics,
        scale: CGFloat,
        rootLayer: CALayer,
        desktopImage: CGImage? = nil,
        applyEdit: @escaping (LaunchpadEdit) -> Void
    ) {
        self.layout = layout
        self.metrics = metrics
        self.scale = scale
        self.applyEdit = applyEdit
        mainPages = SpringboardPagedGrids(
            metrics: metrics,
            scale: scale,
            pageStride: metrics.springboardFrame.width,
            pageFrame: { metrics.pageFrame(at: $0) }
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = rootLayer.bounds
        // Keep y up inside, whatever the window's root layer does.
        containerLayer.isGeometryFlipped = rootLayer.contentsAreFlipped()

        desktopContainerLayer.frame = containerLayer.bounds
        desktopContainerLayer.shouldRasterize = true
        desktopContainerLayer.rasterizationScale = scale
        desktopContainerLayer.filters = QuartzCorePrivate.desktopBackgroundFilters()
        desktopContainerLayer.addSublayer(Self.makeDesktopLayer(image: desktopImage, frame: containerLayer.bounds))
        containerLayer.addSublayer(desktopContainerLayer)

        springboardLayer.frame = metrics.springboardFrame
        springboardLayer.masksToBounds = false
        mainPages.scrollLayer.frame = metrics.scrollFrame
        mainPages.pagerControlLayer.frame = metrics.pagerControlFrame
        searchFieldLayer.frame = metrics.searchFieldFrame
        searchFieldLayer.configure(scale: scale)
        noResultsLayer.layout(in: metrics.pageFrame(at: 0).offsetBy(dx: metrics.scrollFrame.minX, dy: metrics.scrollFrame.minY), scale: scale)

        springboardLayer.addSublayer(noResultsLayer)
        springboardLayer.addSublayer(mainPages.scrollLayer)
        springboardLayer.addSublayer(mainPages.pagerControlLayer)
        springboardLayer.addSublayer(searchFieldLayer)
        containerLayer.addSublayer(springboardLayer)
        rootLayer.addSublayer(containerLayer)
        CATransaction.commit()

        mainPages.currentPageDidChange = { [weak self] in
            self?.select(itemAt: nil)
        }
        showMainPages(pageIndex: 0)
    }

    /// The wallpaper, stretched over the screen; 15's radial gradient when there is no picture
    /// (`-[Springboard _newDesktopLayer]`, 15.5 `0x100090670`).
    private static func makeDesktopLayer(image: CGImage?, frame: CGRect) -> CALayer {
        guard let image else {
            let gradientLayer = CAGradientLayer()
            gradientLayer.type = .radial
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.6)
            gradientLayer.endPoint = CGPoint(x: 1.2, y: 1.5)
            gradientLayer.colors = [
                CGColor(red: 0.251, green: 0.254, blue: 0.284, alpha: 1),
                CGColor(red: 0.132, green: 0.132, blue: 0.147, alpha: 1),
            ]
            gradientLayer.frame = frame
            return gradientLayer
        }
        let desktopLayer = CALayer()
        desktopLayer.frame = frame
        desktopLayer.contents = image
        return desktopLayer
    }

    // MARK: - Showing and hiding

    /// What grows and shrinks as the springboard appears: the open folder if there is one, else the pages.
    private var scalingLayer: CALayer {
        folderPanel?.folderLayer ?? springboardLayer
    }

    /// Sets how far shown the springboard is, without animation: the whole thing fades with it while the
    /// pages shrink from 1.05 to their size (`-[LPSpringboard _animateToVisibility:]`, 15.5 `0x1000B209C`).
    func setVisibility(_ visibility: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.opacity = Float(min(max(visibility, 0), 1))
        if !SpringboardPreferences.reducesMotion {
            let gridScale = SpringboardPinch.gridScale(forVisibility: visibility)
            scalingLayer.transform = CATransform3DMakeScale(gridScale, gridScale, 1)
        }
        CATransaction.commit()
    }

    /// 15's entrance: from hidden, fade in while the pages shrink from 1.05, ease-in
    /// (`-[Springboard performEnterAnimation:]`, `0x10002E1C8`).
    func animateEntrance(duration: CFTimeInterval) {
        setVisibility(0)
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        containerLayer.opacity = 1
        scalingLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// 15's exit: fade out while the pages grow to 1.05, ease-out (`-[Springboard performExitAnimation:]`,
    /// `0x1000303C4`).
    func animateExit(duration: CFTimeInterval, completion: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                completion()
            }
        }
        if !SpringboardPreferences.reducesMotion {
            scalingLayer.transform = CATransform3DMakeScale(1.05, 1.05, 1)
        }
        containerLayer.opacity = 0
        CATransaction.commit()
    }

    /// Ends whatever is in progress as the springboard starts to go: a drag is cancelled, a new name
    /// is kept, a pending search is dropped.
    func prepareForHiding() {
        if dragSession != nil {
            cancelDrag()
        }
        commitRenaming()
        searchTask?.cancel()
    }

    func tearDown() {
        searchTask?.cancel()
        mainPages.tearDown()
        folderPanel?.pages.tearDown()
        dragSession?.cancelTimers()
        containerLayer.removeFromSuperlayer()
    }

    var pageCount: Int {
        mainPages.pageGrids.count
    }

    /// Whether nothing is in motion that a new layout would disturb.
    var isIdle: Bool {
        dragSession == nil && !isAnimatingFolder
    }

    // MARK: - Pages

    func showMainPages(pageIndex: Int) {
        mainPages.showPages(layout.pages.map(\.items), rowCount: metrics.input.rowCount, pageIndex: pageIndex) { [weak self] itemLayer in
            self?.putIcons(in: itemLayer)
        }
        isShowingSearchResults = false
        selectedItemIndex = nil
    }

    func putIcons(in itemLayer: SpringboardItemLayer) {
        guard let item = itemLayer.item else { return }
        switch item {
        case .application(let application):
            itemLayer.setApplicationIcon(icon(for: application, side: metrics.iconSide), compositingFilterName: SpringboardIconProvider.shared.glassCompositingFilterName)
        case .folder(let folder):
            let thumbnailSide = SpringboardItemLayer.thumbnailSide(forIconSide: metrics.iconSide)
            itemLayer.setFolderThumbnails((folder.pages.first?.applications ?? []).map { icon(for: $0, side: thumbnailSide) })
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
        let itemLayers = mainPages.itemLayers + (folderPanel?.pages.itemLayers ?? [])
        for itemLayer in itemLayers {
            switch itemLayer.item {
            case .application(let application) where application.bundleURL == bundleURL:
                putIcons(in: itemLayer)
            case .folder(let folder) where (folder.pages.first?.applications ?? []).contains(where: { $0.bundleURL == bundleURL }):
                putIcons(in: itemLayer)
            default:
                break
            }
        }
    }

    /// Takes the layout as stored after an edit or a reconciliation. Waits while something is moving.
    func replaceLayout(_ newLayout: LaunchpadLayout) {
        guard isIdle else {
            pendingLayout = newLayout
            return
        }
        pendingLayout = nil
        guard newLayout != layout else { return }
        layout = newLayout
        if isShowingSearchResults {
            showSearchResults()
        } else {
            showMainPages(pageIndex: mainPages.currentPageIndex)
        }
        guard let folderPanel else { return }
        guard let updatedFolder = newLayout.folders.first(where: { $0.identifier == folderPanel.folder.identifier }) else {
            // The folder is gone — emptied or dissolved by the edit.
            folderPanel.folderLayer.removeFromSuperlayer()
            folderPanel.pages.tearDown()
            self.folderPanel = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            springboardLayer.opacity = 1
            springboardLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            return
        }
        folderPanel.update(with: updatedFolder) { [weak self] itemLayer in
            self?.putIcons(in: itemLayer)
        }
        hideFolderIcon(of: updatedFolder)
    }

    func applyPendingLayoutIfIdle() {
        if let pendingLayout, isIdle {
            replaceLayout(pendingLayout)
        }
    }

    private func folderItemLayer(of folder: LaunchpadFolder) -> SpringboardItemLayer? {
        mainPages.itemLayers.first { $0.item?.identifier == folder.identifier }
    }

    private func hideFolderIcon(of folder: LaunchpadFolder) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        folderItemLayer(of: folder)?.opacity = 0
        CATransaction.commit()
    }

    func pages(for context: GridContext) -> SpringboardPagedGrids {
        switch context {
        case .main: mainPages
        case .folder: folderPanel?.pages ?? mainPages
        }
    }

    // MARK: - Selection

    private func select(itemAt itemIndex: Int?) {
        for (index, itemLayer) in currentItemLayers.enumerated() {
            itemLayer.isSelected = index == itemIndex
        }
        selectedItemIndex = itemIndex
    }

    private var currentItemLayers: [SpringboardItemLayer] {
        mainPages.currentPageGrid?.itemLayers ?? []
    }

    private var currentItems: [LaunchpadItem] {
        mainPages.currentPageGrid?.items ?? []
    }

    // MARK: - Folders

    func openFolder(_ folder: LaunchpadFolder, from folderItemLayer: SpringboardItemLayer, completion: (@MainActor () -> Void)? = nil) {
        guard folderPanel == nil, !isAnimatingFolder else { return }
        select(itemAt: nil)
        let newFolderPanel = SpringboardFolderPanel(folder: folder, metrics: metrics, scale: scale) { [weak self] itemLayer in
            self?.putIcons(in: itemLayer)
        }
        folderPanel = newFolderPanel
        isAnimatingFolder = true
        newFolderPanel.animateOpen(from: folderItemLayer, springboardLayer: springboardLayer, containerLayer: containerLayer) { [weak self] in
            self?.isAnimatingFolder = false
            completion?()
            self?.applyPendingLayoutIfIdle()
        }
    }

    func closeFolder(animated: Bool = true, completion: (@MainActor () -> Void)? = nil) {
        guard let folderPanel, !isAnimatingFolder else { return }
        commitRenaming()
        let folderItemLayer = folderItemLayer(of: folderPanel.folder)
        isAnimatingFolder = true
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.folderPanel = nil
            self.isAnimatingFolder = false
            completion?()
            self.applyPendingLayoutIfIdle()
        }
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            folderPanel.folderLayer.removeFromSuperlayer()
            folderItemLayer?.opacity = 1
            springboardLayer.opacity = 1
            springboardLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            folderPanel.pages.tearDown()
            finish()
            return
        }
        folderPanel.animateClose(to: folderItemLayer, springboardLayer: springboardLayer, completion: finish)
    }

    // MARK: - Renaming

    private func startRenaming() {
        guard let folderPanel, renamingTitle == nil else { return }
        renamingTitle = folderPanel.folder.title
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        folderPanel.titleLayer.isHidden = true
        folderPanel.titleEditorLayer.isHidden = false
        folderPanel.titleEditorLayer.setText(folderPanel.folder.title)
        folderPanel.titleEditorLayer.startBlinking()
        CATransaction.commit()
    }

    /// Ends renaming and stores the new name; an empty name keeps the old one, as in 15.
    func commitRenaming() {
        guard let folderPanel, let renamingTitle else { return }
        self.renamingTitle = nil
        let newTitle = renamingTitle.trimmingCharacters(in: .whitespaces)
        endRenaming(in: folderPanel)
        guard !newTitle.isEmpty, newTitle != folderPanel.folder.title else { return }
        folderPanel.setTitle(newTitle)
        folderItemLayer(of: folderPanel.folder)?.labelLayer.setString(newTitle, contentsScale: scale)
        applyEdit(.renameFolder(folderPanel.folder.identifier, title: newTitle))
    }

    private func cancelRenaming() {
        guard let folderPanel, renamingTitle != nil else { return }
        renamingTitle = nil
        endRenaming(in: folderPanel)
    }

    private func endRenaming(in folderPanel: SpringboardFolderPanel) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        folderPanel.titleEditorLayer.isHidden = true
        folderPanel.titleLayer.isHidden = false
        CATransaction.commit()
    }

    private func handleRenamingKeyDown(keyCode: Int64, characters: String, modifierFlags: CGEventFlags) {
        guard let folderPanel, var title = renamingTitle else { return }
        switch keyCode {
        case SpringboardKeyCode.returnKey, SpringboardKeyCode.keypadEnter:
            commitRenaming()
            return
        case SpringboardKeyCode.escape:
            cancelRenaming()
            return
        case SpringboardKeyCode.delete:
            guard !title.isEmpty else { return }
            title.removeLast()
        default:
            guard Self.isTypedText(characters, modifierFlags: modifierFlags) else { return }
            title += characters
        }
        renamingTitle = title
        folderPanel.titleEditorLayer.setText(title)
    }

    private static func isTypedText(_ characters: String, modifierFlags: CGEventFlags) -> Bool {
        !modifierFlags.contains(.maskCommand)
            && !modifierFlags.contains(.maskControl)
            && !characters.isEmpty
            && !characters.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) }
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
            pageIndexBeforeSearch = mainPages.currentPageIndex
        }
        let results = SpringboardSearch.applications(matching: searchText, in: layout) { $0.fileName }
        let itemsPerPage = metrics.input.rowCount * metrics.input.columnCount
        let resultPages = stride(from: 0, to: results.count, by: itemsPerPage).map { pageStart in
            results[pageStart..<min(pageStart + itemsPerPage, results.count)].map(LaunchpadItem.application)
        }
        mainPages.showPages(
            resultPages,
            rowCount: metrics.input.rowCount,
            pageIndex: 0,
            centeredRowOffset: { [metrics] itemCount in metrics.centeredRowOffset(forItemCount: itemCount) }
        ) { [weak self] itemLayer in
            self?.putIcons(in: itemLayer)
        }
        isShowingSearchResults = true
        selectedItemIndex = nil
        CATransaction.begin()
        CATransaction.setDisableActions(!results.isEmpty)
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
        showMainPages(pageIndex: pageIndexBeforeSearch)
    }

    private func clearSearch() {
        searchText = ""
        searchTextDidChange()
    }

    // MARK: - Keys

    func handleKeyDown(keyCode: Int64, characters: String, modifierFlags: CGEventFlags) -> Action {
        guard !isAnimatingFolder else { return .none }
        if renamingTitle != nil {
            handleRenamingKeyDown(keyCode: keyCode, characters: characters, modifierFlags: modifierFlags)
            return .none
        }
        // 15's order for Escape: cancel a drag, close a folder, clear the search, then close Launchpad.
        if keyCode == SpringboardKeyCode.escape {
            if dragSession != nil {
                cancelDrag()
                return .none
            }
            if folderPanel != nil {
                closeFolder()
                return .none
            }
            guard searchText.isEmpty else {
                clearSearch()
                return .none
            }
            return .dismiss(reason: "escape")
        }
        guard folderPanel == nil, dragSession == nil else { return .none }

        let hasCommand = modifierFlags.contains(.maskCommand)
        switch keyCode {
        case SpringboardKeyCode.returnKey, SpringboardKeyCode.keypadEnter:
            return actionForSelectedItem()
        case SpringboardKeyCode.leftArrow where hasCommand:
            turnPageKeepingSelection(by: -1)
        case SpringboardKeyCode.rightArrow where hasCommand:
            turnPageKeepingSelection(by: 1)
        case SpringboardKeyCode.downArrow where hasCommand:
            return actionForSelectedItem(opensFoldersOnly: true)
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
            guard Self.isTypedText(characters, modifierFlags: modifierFlags) else { return .none }
            searchText += characters
            searchTextDidChange()
        }
        return .none
    }

    private func navigate(_ direction: SpringboardNavigation.Direction) {
        select(itemAt: SpringboardNavigation.selectedIndex(
            after: direction,
            from: selectedItemIndex,
            itemCount: currentItems.count,
            columnCount: metrics.input.columnCount
        ))
    }

    /// Command-arrows turn the page; a selection moves to the new page's first item.
    private func turnPageKeepingSelection(by pageOffset: Int) {
        let hadSelection = selectedItemIndex != nil
        mainPages.turn(toPageAt: mainPages.currentPageIndex + pageOffset)
        if hadSelection, !currentItems.isEmpty {
            select(itemAt: 0)
        }
    }

    /// Return launches the selected application or opens the selected folder; Command-Down only opens.
    private func actionForSelectedItem(opensFoldersOnly: Bool = false) -> Action {
        guard let selectedItemIndex, currentItems.indices.contains(selectedItemIndex), currentItemLayers.indices.contains(selectedItemIndex) else { return .none }
        let itemLayer = currentItemLayers[selectedItemIndex]
        switch currentItems[selectedItemIndex] {
        case .application(let application):
            guard !opensFoldersOnly else { return .none }
            return launchAction(for: application, itemLayer: itemLayer)
        case .folder(let folder):
            openFolder(folder, from: itemLayer)
            return .none
        }
    }

    private func launchAction(for application: LaunchpadApplication, itemLayer: SpringboardItemLayer) -> Action {
        .launch(application, iconFrame: itemLayer.imageLayer.convert(itemLayer.imageLayer.bounds, to: containerLayer), iconImage: itemLayer.imageLayer.contents)
    }

    // MARK: - Pointer

    func handleMouseDown(at containerPoint: CGPoint, timestamp: UInt64) -> Action {
        guard !isAnimatingFolder else { return .none }
        mainPages.cancelPendingWheelSettle()
        folderPanel?.pages.cancelPendingWheelSettle()

        if let folderPanel {
            if renamingTitle != nil, !folderPanel.isOnTitle(containerPoint) {
                commitRenaming()
            }
            if folderPanel.isOnTitle(containerPoint) {
                pointerTracking = .folderTitle
                return .none
            }
            guard folderPanel.isInsidePanel(containerPoint) else {
                // 15 closed an open folder as soon as the press landed outside it.
                closeFolder()
                pointerTracking = .none
                return .none
            }
            return beginPress(at: containerPoint, timestamp: timestamp, context: .folder)
        }

        let springboardPoint = springboardLayer.convert(containerPoint, from: containerLayer)
        if metrics.searchFieldFrame.contains(springboardPoint) {
            let fieldPoint = springboardLayer.convert(springboardPoint, to: searchFieldLayer)
            if searchFieldLayer.isOnClearButton(fieldPoint) {
                searchFieldLayer.isClearButtonPressed = true
                pointerTracking = .clearButton
            } else {
                pointerTracking = .searchField
            }
            return .none
        }
        return beginPress(at: containerPoint, timestamp: timestamp, context: .main)
    }

    private func beginPress(at containerPoint: CGPoint, timestamp: UInt64, context: GridContext) -> Action {
        let pages = pages(for: context)
        let pointInPagesSuperlayer = containerLayer.convert(containerPoint, to: pages.scrollLayer.superlayer)
        if let pageIndex = pages.pageIndexOfIndicator(at: pointInPagesSuperlayer) {
            pointerTracking = .pagerIndicator(context: context, pageIndex: pageIndex)
            return .none
        }
        if let (pageGrid, gridPoint) = pages.pointInCurrentGrid(pointInPagesSuperlayer), let hit = pageGrid.item(at: gridPoint), hit.isOnIcon {
            hit.itemLayer.isDarkened = true
            pointerTracking = .icon(context: context, pageIndex: pages.currentPageIndex, itemIndex: hit.index, itemLayer: hit.itemLayer, startLocation: containerPoint, startTimestamp: timestamp)
            return .none
        }
        pointerTracking = .background(context: context, startLocation: containerPoint, startScrollValue: pages.scrollValue, startTimestamp: timestamp, isDragging: false)
        return .none
    }

    func handleMouseDragged(to containerPoint: CGPoint, timestamp: UInt64) -> Action {
        if dragSession != nil {
            continueDrag(to: containerPoint, timestamp: timestamp)
            return .none
        }
        switch pointerTracking {
        case let .icon(context, pageIndex, itemIndex, itemLayer, startLocation, _):
            // 15 started dragging an icon after 3 points in either direction, no long press needed.
            guard
                abs(containerPoint.x - startLocation.x) >= SpringboardPaging.dragThreshold
                    || abs(containerPoint.y - startLocation.y) >= SpringboardPaging.dragThreshold
            else { return .none }
            pointerTracking = .none
            beginDrag(of: itemLayer, context: context, pageIndex: pageIndex, itemIndex: itemIndex, startLocation: startLocation, location: containerPoint, timestamp: timestamp)
            return .none
        case let .background(context, startLocation, startScrollValue, startTimestamp, isDragging):
            let horizontalMovement = containerPoint.x - startLocation.x
            let hasStartedDragging = isDragging || abs(horizontalMovement) >= SpringboardPaging.dragThreshold
            pointerTracking = .background(context: context, startLocation: startLocation, startScrollValue: startScrollValue, startTimestamp: startTimestamp, isDragging: hasStartedDragging)
            if hasStartedDragging {
                pages(for: context).follow(scrollValue: startScrollValue - horizontalMovement)
            }
            return .none
        case .clearButton:
            let fieldPoint = containerLayer.convert(containerPoint, to: searchFieldLayer)
            searchFieldLayer.isClearButtonPressed = searchFieldLayer.isOnClearButton(fieldPoint)
            return .none
        case .none, .pagerIndicator, .searchField, .folderTitle:
            return .none
        }
    }

    func handleMouseUp(at containerPoint: CGPoint, timestamp: UInt64) -> Action {
        if dragSession != nil {
            endDrag(at: containerPoint, timestamp: timestamp)
            return .none
        }
        defer { pointerTracking = .none }
        switch pointerTracking {
        case let .icon(context, pageIndex, itemIndex, itemLayer, _, _):
            itemLayer.isDarkened = false
            let pages = pages(for: context)
            guard
                pageIndex == pages.currentPageIndex,
                let (pageGrid, gridPoint) = pages.pointInCurrentGrid(containerLayer.convert(containerPoint, to: pages.scrollLayer.superlayer)),
                let hit = pageGrid.item(at: gridPoint),
                hit.index == itemIndex,
                hit.isOnIcon
            else { return .none }
            switch hit.itemLayer.item {
            case .application(let application):
                return launchAction(for: application, itemLayer: hit.itemLayer)
            case .folder(let folder):
                openFolder(folder, from: hit.itemLayer)
                return .none
            case .none:
                return .none
            }
        case let .background(context, startLocation, startScrollValue, startTimestamp, isDragging):
            guard isDragging else {
                guard context == .main else { return .none }
                // 15 closed on a click on the background, search or not (`cancelActionWithEvent:sender:`).
                let movement = hypot(containerPoint.x - startLocation.x, containerPoint.y - startLocation.y)
                return movement < SpringboardPaging.dragThreshold ? .dismiss(reason: "clicked outside the icons") : .none
            }
            pages(for: context).settleDrag(startScrollValue: startScrollValue, startTimestamp: startTimestamp, endTimestamp: timestamp)
            return .none
        case let .pagerIndicator(context, pageIndex):
            let pages = pages(for: context)
            if pages.pageIndexOfIndicator(at: containerLayer.convert(containerPoint, to: pages.scrollLayer.superlayer)) == pageIndex {
                pages.turn(toPageAt: pageIndex)
            }
            return .none
        case .clearButton:
            let wasPressed = searchFieldLayer.isClearButtonPressed
            searchFieldLayer.isClearButtonPressed = false
            if wasPressed {
                clearSearch()
            }
            return .none
        case .folderTitle:
            if let folderPanel, folderPanel.isOnTitle(containerPoint), SpringboardPreferences.allowsRenamingFolders {
                startRenaming()
            }
            return .none
        case .none, .searchField:
            return .none
        }
    }

    // MARK: - Scroll wheel and trackpad

    func handleScrollWheel(_ scrollWheel: SpringboardInputEvent.ScrollWheel, timestamp: UInt64) -> Action {
        guard !isAnimatingFolder, dragSession == nil else { return .none }
        pages(for: folderPanel == nil ? .main : .folder).handleScrollWheel(scrollWheel, timestamp: timestamp)
        return .none
    }

    // MARK: - Log

    /// What the Dock's grid made of the first page, for the log: classes, counts and a few frames.
    var firstPageSummary: String {
        guard let firstGrid = mainPages.pageGrids.first else { return "no pages" }
        let itemLayers = firstGrid.itemLayers
        itemLayers.forEach { $0.layoutIfNeeded() }
        func describe(_ itemLayer: SpringboardItemLayer?) -> String {
            guard let itemLayer else { return "none" }
            return "cell \(NSStringFromRect(itemLayer.frame)) icon \(NSStringFromRect(itemLayer.iconFrame)) label \(NSStringFromRect(itemLayer.labelLayer.frame)) \"\(itemLayer.item?.title ?? "")\""
        }
        let gridClassName = String(cString: object_getClassName(firstGrid.gridLayer))
        let textClassName = String(cString: object_getClassName(itemLayers.first?.labelLayer.textLayer ?? CATextLayer()))
        let iconCount = itemLayers.filter { $0.imageLayer.contents != nil }.count
        let folderSummary = itemLayers.first(where: \.isFolder).map { folderLayer in
            "folder \"\(folderLayer.item?.title ?? "")\" square \(NSStringFromRect(folderLayer.folderBackdropFrame)) with \(folderLayer.thumbnailLayers.count) thumbnail layer(s), first \(folderLayer.thumbnailLayers.first.map { NSStringFromRect($0.frame) } ?? "none")"
        } ?? "no folder"
        return "grid \(gridClassName) \(NSStringFromRect(firstGrid.gridLayer.frame)), \(itemLayers.count)/\(firstGrid.items.count) items, titles \(textClassName), \(iconCount) with an image; first \(describe(itemLayers.first)); last \(describe(itemLayers.last)); \(folderSummary)"
    }

    /// The geometry, for the log.
    var geometryDescription: String {
        "page \(Int(metrics.pageSize.width))×\(Int(metrics.pageSize.height)), cell \(Int(metrics.cellSize.width))×\(Int(metrics.cellSize.height)), icon \(Int(metrics.iconSide)), \(pageCount) page(s), Dock \(metrics.input.dockOrientation.rawValue) \(Int(metrics.input.dockThickness)), notch \(Int(metrics.input.notchHeight))"
    }
}
