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
    /// Glass over whatever is behind the window, where 15 had the blurred wallpaper; nil off screen.
    private(set) var background: SpringboardBackground?
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
    /// True from the moment a folder starts to close until its panel is gone.
    private var isClosingFolder = false
    /// The open folder's name while it is being renamed, with the selection.
    private var renaming: SpringboardTextEditing?
    /// The latest stored layout, waiting until nothing it would disturb is moving.
    private(set) var pendingLayout: LaunchpadLayout?
    /// The main page as a drag that ended in a folder left it — its icons with a gap where the dragged one
    /// was — kept until 250 ms after that folder closes, when the gap closes (`Pager_hideGroupAfter250ms`,
    /// 15.5 `0x100058B88`). Until then the main pages are not rebuilt.
    var mainPagePlaceholder: (pageIndex: Int, arrangedLayers: [SpringboardItemLayer?])?

    private enum PointerTracking {
        case none
        case icon(context: GridContext, pageIndex: Int, itemIndex: Int, itemLayer: SpringboardItemLayer, startLocation: CGPoint, startTimestamp: UInt64)
        case background(context: GridContext, startLocation: CGPoint, startScrollValue: CGFloat, startTimestamp: UInt64, isDragging: Bool)
        case pagerIndicator(context: GridContext, pageIndex: Int)
        case clearButton
        case searchField
        case folderTitle
        /// A press in the rename field, which drags out a selection: by character, or by word from
        /// `doubleClickedWord` after a double-click.
        case titleEditor(doubleClickedWord: Range<Int>?)
    }

    private var pointerTracking: PointerTracking = .none
    /// Set while an icon is being dragged; see `SpringboardInterface+Dragging.swift`.
    var dragSession: SpringboardDragSession?

    /// Fires once a press on an icon has been held long enough to switch jiggle mode.
    private var longPressTask: Task<Void, Never>?
    /// The icon whose long press switched jiggle mode; its release neither launches nor opens.
    private var longPressedItemLayer: SpringboardItemLayer?
    private var optionKeyJiggle = SpringboardOptionKeyJiggle()

    /// The pages in front: the open folder's, or the main ones. Jiggle mode is theirs, as 15's
    /// `-[ECSBPager setDeleting:]` gave it to the shown folder rather than the main pages.
    var frontPages: SpringboardPagedGrids {
        folderPanel?.pages ?? mainPages
    }

    /// - Parameters:
    ///   - backgroundStyle: What goes behind the pages; nil for nothing. The Dock's glass may only be asked
    ///     for once the Dock is up, so the off-screen self-check goes without.
    ///   - wallpaperImage: The wallpaper as captured on opening, for the wallpaper style; nil falls back to
    ///     15's own gradient.
    ///   - position: Where to open: the page, and the folder open over it, that the last showing was left on.
    init(
        layout: LaunchpadLayout,
        metrics: SpringboardMetrics,
        scale: CGFloat,
        rootLayer: CALayer,
        backgroundStyle: SpringboardBackground.Style? = .wallpaper,
        wallpaperImage: CGImage? = nil,
        position: SpringboardPosition = .firstPage,
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
        // The screen, not the root layer's bounds: the Dock's window has not sized its root layer yet, and
        // anything sized from it — the background — comes out empty.
        containerLayer.frame = CGRect(origin: .zero, size: metrics.input.screenSize)
        // Keep y up inside, whatever the window's root layer does.
        containerLayer.isGeometryFlipped = rootLayer.contentsAreFlipped()
        if backgroundStyle == .glass {
            // Fading as a group would draw everything off screen, where the glass has nothing behind it;
            // the Command-Tab switcher turns both off for its glass too.
            containerLayer.allowsGroupOpacity = false
            containerLayer.setValue(false, forKey: "allowsGroupBlending")
        }

        if let backgroundStyle {
            let background = SpringboardBackground(style: backgroundStyle, frame: containerLayer.bounds, scale: scale, wallpaperImage: wallpaperImage)
            containerLayer.addSublayer(background.layer)
            self.background = background
        }

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
        restore(position)
    }

    // MARK: - Position

    /// Where the springboard stands now, for the next showing to open there. Search results count as the
    /// page they replaced, since 15 cleared the search once it had hidden and went back to that page
    /// (`-[ECSBSpringboard clearFilteredItems]`, 15.5 `0x1000F2B9C`). A folder already closing, or one a
    /// drag made that is not stored yet, counts as closed.
    var position: SpringboardPosition {
        let mainPageIndex = isShowingSearchResults ? pageIndexBeforeSearch : mainPages.currentPageIndex
        guard let folderPanel, !isClosingFolder, !folderPanel.folder.isUnsaved else {
            return SpringboardPosition(mainPageIndex: mainPageIndex)
        }
        return SpringboardPosition(
            mainPageIndex: mainPageIndex,
            openFolder: SpringboardPosition.OpenFolder(identifier: folderPanel.folder.identifier, pageIndex: folderPanel.pages.currentPageIndex)
        )
    }

    /// Shows the page `position` names and opens its folder over it, all without animation, so that the
    /// entrance plays on whichever is in front.
    private func restore(_ position: SpringboardPosition) {
        let resolution = position.resolved(in: layout)
        showMainPages(pageIndex: resolution.mainPageIndex)
        guard let folder = resolution.folder, let folderItemLayer = folderItemLayer(of: folder) else { return }
        let restoredFolderPanel = SpringboardFolderPanel(
            folder: folder,
            metrics: metrics,
            scale: scale,
            pageIndex: resolution.folderPageIndex
        ) { [weak self] itemLayer in
            self?.putIcons(in: itemLayer)
        }
        folderPanel = restoredFolderPanel
        restoredFolderPanel.showOpen(over: folderItemLayer, springboardLayer: springboardLayer, containerLayer: containerLayer)
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
        cancelLongPress()
    }

    func tearDown() {
        searchTask?.cancel()
        cancelLongPress()
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

    /// Takes the layout as stored after an edit or a reconciliation. Waits while something is moving; while
    /// the main page keeps a drag's gap, only the open folder takes it.
    func replaceLayout(_ newLayout: LaunchpadLayout) {
        guard isIdle else {
            pendingLayout = newLayout
            return
        }
        if mainPagePlaceholder != nil {
            pendingLayout = newLayout
            updateOpenFolder(from: newLayout)
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
        updateOpenFolder(from: newLayout)
    }

    /// Gives the open folder its stored state; closes it if the folder is gone.
    private func updateOpenFolder(from newLayout: LaunchpadLayout) {
        guard let folderPanel else { return }
        guard let updatedFolder = storedFolder(for: folderPanel.folder, in: newLayout) else {
            // Not stored yet: the drop that makes it is still to come.
            guard !folderPanel.folder.isUnsaved else { return }
            // The folder is gone — emptied or dissolved by the edit.
            folderPanel.folderLayer.removeFromSuperlayer()
            folderPanel.pages.tearDown()
            self.folderPanel = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            springboardLayer.opacity = 1
            springboardLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            // Nothing will close for the gap to wait for.
            closeMainPagePlaceholderNow()
            return
        }
        folderPanel.update(with: updatedFolder) { [weak self] itemLayer in
            self?.putIcons(in: itemLayer)
        }
        hideFolderIcon(of: updatedFolder)
    }

    /// `folder` as stored in `newLayout`. A folder still unsaved is found by its first application,
    /// the one the folder was made around.
    func storedFolder(for folder: LaunchpadFolder, in newLayout: LaunchpadLayout) -> LaunchpadFolder? {
        if let sameFolder = newLayout.folders.first(where: { $0.identifier == folder.identifier }) {
            return sameFolder
        }
        guard folder.isUnsaved, let firstApplication = folder.applications.first else { return nil }
        return newLayout.folders.first { storedFolder in
            storedFolder.applications.contains { $0.identifier == firstApplication.identifier }
        }
    }

    func applyPendingLayoutIfIdle() {
        if let pendingLayout, isIdle {
            replaceLayout(pendingLayout)
        }
    }

    /// The main page's icon of `folder`; for a folder made by dragging, the icon it was made in, until the
    /// main page is rebuilt.
    func folderItemLayer(of folder: LaunchpadFolder) -> SpringboardItemLayer? {
        mainPages.itemLayers.first { $0.item?.identifier == folder.identifier }
            ?? mainPages.itemLayers.first { $0.item?.identifier == .unsavedFolder }
    }

    func hideFolderIcon(of folder: LaunchpadFolder) {
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
        let newFolderPanel = SpringboardFolderPanel(
            folder: folder,
            metrics: metrics,
            scale: scale
        ) { [weak self] itemLayer in
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
        // 15 ended the folder's jiggling at once, before its panel closed (`-[ECSBPager hideGroup]`,
        // 15.5 `0x100058350`).
        folderPanel.pages.isJiggling = false
        let closingFolder = folderPanel.folder
        let folderItemLayer = folderItemLayer(of: closingFolder)
        isAnimatingFolder = true
        isClosingFolder = true
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.folderPanel = nil
            self.isClosingFolder = false
            // The page may have been rebuilt meanwhile; show the folder's icon on the page as it is now.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.folderItemLayer(of: closingFolder)?.opacity = 1
            CATransaction.commit()
            completion?()
            guard self.mainPagePlaceholder != nil else {
                self.isAnimatingFolder = false
                self.applyPendingLayoutIfIdle()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated {
                    self?.closeMainPagePlaceholder()
                }
            }
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

    /// Closes the gap a drag left on the main page without waiting for a folder to close; input waits
    /// meanwhile, as during a folder's animation.
    func closeMainPagePlaceholderNow() {
        guard mainPagePlaceholder != nil else { return }
        isAnimatingFolder = true
        closeMainPagePlaceholder()
    }

    /// 250 ms after the folder closed, the gap a drag left on the main page closes with the default
    /// animation; then the stored layout may rebuild the page.
    private func closeMainPagePlaceholder() {
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.mainPagePlaceholder = nil
            self.isAnimatingFolder = false
            self.applyPendingLayoutIfIdle()
        }
        guard let placeholder = mainPagePlaceholder, mainPages.pageGrids.indices.contains(placeholder.pageIndex) else {
            finish()
            return
        }
        let pageGrid = mainPages.pageGrids[placeholder.pageIndex]
        CATransaction.begin()
        CATransaction.setAnimationDuration(SpringboardFolderPanel.animationDuration)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                finish()
            }
        }
        for (index, itemLayer) in placeholder.arrangedLayers.compactMap({ $0 }).enumerated() {
            itemLayer.setUntransformedFrame(pageGrid.cellFrame(at: index))
            itemLayer.opacity = index < pageGrid.capacity ? 1 : 0
        }
        CATransaction.commit()
    }

    /// Takes an open or opening folder away at once, for a drag cancelled while it opened.
    func dismissFolderImmediately() {
        guard let folderPanel else { return }
        let dismissedFolder = folderPanel.folder
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        folderPanel.folderLayer.removeFromSuperlayer()
        folderItemLayer(of: dismissedFolder)?.opacity = 1
        springboardLayer.opacity = 1
        springboardLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        folderPanel.pages.tearDown()
        self.folderPanel = nil
        isAnimatingFolder = false
    }

    // MARK: - Renaming

    /// Starts renaming with the whole name selected, as 15's field did.
    private func startRenaming() {
        guard let folderPanel, renaming == nil else { return }
        let editing = SpringboardTextEditing(selectingAllOf: folderPanel.folder.title)
        renaming = editing
        // 15 took the focus from the search field while a title was edited.
        setSearchFieldFocus(false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        folderPanel.titleLayer.isHidden = true
        folderPanel.titleEditorLayer.isHidden = false
        folderPanel.titleEditorLayer.show(editing)
        CATransaction.commit()
    }

    /// Ends renaming and stores the new name; an empty name keeps the old one, as in 15.
    func commitRenaming() {
        guard let folderPanel, let renaming else { return }
        self.renaming = nil
        let newTitle = renaming.text.trimmingCharacters(in: .whitespaces)
        endRenaming(in: folderPanel)
        guard !newTitle.isEmpty, newTitle != folderPanel.folder.title else { return }
        folderPanel.setTitle(newTitle)
        folderItemLayer(of: folderPanel.folder)?.labelLayer.setString(newTitle, contentsScale: scale)
        applyEdit(.renameFolder(folderPanel.folder.identifier, title: newTitle))
    }

    private func endRenaming(in folderPanel: SpringboardFolderPanel) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        folderPanel.titleEditorLayer.isHidden = true
        folderPanel.titleLayer.isHidden = false
        CATransaction.commit()
    }

    private func handleRenamingKeyDown(keyCode: Int64, characters: String, modifierFlags: CGEventFlags) {
        guard var editing = renaming, let command = SpringboardTextEditingCommand(keyCode: keyCode, characters: characters, modifierFlags: modifierFlags) else { return }
        switch command {
        case .endEditing:
            commitRenaming()
            return
        case let .insert(typedText):
            editing.insert(typedText)
        case let .move(movement, extendingSelection):
            editing.move(movement, extendingSelection: extendingSelection)
        case let .delete(deletion):
            editing.delete(deletion)
        case .selectAll:
            editing.selectAll()
        }
        showRenaming(editing)
    }

    private func showRenaming(_ editing: SpringboardTextEditing) {
        renaming = editing
        folderPanel?.titleEditorLayer.show(editing)
    }

    /// A press in the rename field, at `editorPoint` in the editor's coordinates: one click puts the caret
    /// there, or with Shift moves the selection's end there; two select a word, three the whole name.
    private func pressInRenameField(at editorPoint: CGPoint, clickCount: Int64, extendsSelection: Bool) {
        guard let folderPanel, var editing = renaming else { return }
        let editorLayer = folderPanel.titleEditorLayer
        switch clickCount {
        case ...1:
            editing.placeCaret(at: editorLayer.caretOffset(at: editorPoint), extendingSelection: extendsSelection)
            pointerTracking = .titleEditor(doubleClickedWord: nil)
        case 2:
            let wordRange = editing.wordRange(atCharacterOffset: editorLayer.characterOffset(at: editorPoint))
            editing.select(wordRange)
            pointerTracking = .titleEditor(doubleClickedWord: wordRange)
        default:
            editing.selectAll()
            pointerTracking = .none
        }
        showRenaming(editing)
    }

    /// A drag from a press in the rename field moves the selection's end with it, by character, or by
    /// word after a double-click, always keeping the word double-clicked.
    private func dragInRenameField(to editorPoint: CGPoint, doubleClickedWord: Range<Int>?) {
        guard let folderPanel, var editing = renaming else { return }
        let editorLayer = folderPanel.titleEditorLayer
        if let doubleClickedWord {
            let draggedWord = editing.wordRange(atCharacterOffset: editorLayer.characterOffset(at: editorPoint))
            editing.select(
                min(doubleClickedWord.lowerBound, draggedWord.lowerBound)..<max(doubleClickedWord.upperBound, draggedWord.upperBound),
                caretAtStart: draggedWord.lowerBound < doubleClickedWord.lowerBound
            )
        } else {
            editing.placeCaret(at: editorLayer.caretOffset(at: editorPoint), extendingSelection: true)
        }
        showRenaming(editing)
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

    /// A click into the field or a typed key makes it active, the loupe and the placeholder moving to the
    /// left, and gives it the focus, with a blinking caret (`-[ECSBLayer leftMouseDown:in:]`, 15.5
    /// `0x100082AB4`; `-[ECSBLayer keyDown:]`, `0x100081AB0`).
    private func activateSearchField() {
        searchFieldLayer.isActive = true
        searchFieldLayer.hasFocus = true
    }

    /// Without the focus and with nothing typed, the field goes back to its inactive look (`sub_100064748`).
    private func setSearchFieldFocus(_ hasFocus: Bool) {
        guard hasFocus else {
            searchFieldLayer.hasFocus = false
            if searchText.isEmpty {
                searchFieldLayer.isActive = false
            }
            return
        }
        activateSearchField()
    }

    // MARK: - Keys

    func handleKeyDown(keyCode: Int64, characters: String, modifierFlags: CGEventFlags) -> Action {
        guard !isAnimatingFolder else { return .none }
        if renaming != nil {
            handleRenamingKeyDown(keyCode: keyCode, characters: characters, modifierFlags: modifierFlags)
            return .none
        }
        // 15's order for Escape: cancel a drag, end jiggle mode, close a folder, clear the search, then
        // close Launchpad.
        if keyCode == SpringboardKeyCode.escape {
            if dragSession != nil {
                cancelDrag()
                return .none
            }
            if frontPages.isJiggling {
                frontPages.isJiggling = false
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
            // 15 moved the focus into the field and out again.
            setSearchFieldFocus(!searchFieldLayer.hasFocus)
        default:
            guard SpringboardTextEditingCommand.isTypedText(characters, modifierFlags: modifierFlags) else { return .none }
            activateSearchField()
            searchText += characters
            searchTextDidChange()
        }
        return .none
    }

    /// Holding Option jiggles the icons in front, and letting it go stops them
    /// (`-[ECSBSpringboard flagsChanged:]`, 15.5 `0x1000F37AC`).
    func handleModifiersChanged(_ modifierFlags: CGEventFlags) {
        guard renaming == nil else { return }
        let pages = frontPages
        pages.isJiggling = optionKeyJiggle.isJiggling(afterOptionIsDown: modifierFlags.contains(.maskAlternate), isJiggling: pages.isJiggling)
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

    /// - Parameter clickCount: 2 for the second press of a double-click, and so on.
    func handleMouseDown(at containerPoint: CGPoint, timestamp: UInt64, modifierFlags: CGEventFlags = [], clickCount: Int64 = 1) -> Action {
        // A press while a drop is still settling waits, as one during a folder's animation does.
        guard !isAnimatingFolder, dragSession == nil else { return .none }
        cancelLongPress()
        mainPages.cancelPendingWheelSettle()
        folderPanel?.pages.cancelPendingWheelSettle()

        if let folderPanel {
            if renaming != nil {
                // 15's text field took every press inside its box; any other press ends the renaming.
                guard !folderPanel.isInTitleEditor(containerPoint) else {
                    pressInRenameField(
                        at: folderPanel.pointInTitleEditor(containerPoint),
                        clickCount: clickCount,
                        extendsSelection: modifierFlags.contains(.maskShift)
                    )
                    return .none
                }
                commitRenaming()
            }
            if folderPanel.isOnTitle(containerPoint) {
                pointerTracking = .folderTitle
                return .none
            }
            guard folderPanel.isInsidePanel(containerPoint) else {
                // 15 closed an open folder as soon as the press landed outside it; a press beside the
                // title's text closed it too.
                closeFolder()
                pointerTracking = .none
                return .none
            }
            return beginPress(at: containerPoint, timestamp: timestamp, context: .folder, modifierFlags: modifierFlags)
        }

        let springboardPoint = springboardLayer.convert(containerPoint, from: containerLayer)
        if metrics.searchFieldFrame.contains(springboardPoint) {
            let fieldPoint = springboardLayer.convert(springboardPoint, to: searchFieldLayer)
            if searchFieldLayer.isOnClearButton(fieldPoint) {
                searchFieldLayer.isClearButtonPressed = true
                pointerTracking = .clearButton
            } else {
                activateSearchField()
                pointerTracking = .searchField
            }
            return .none
        }
        return beginPress(at: containerPoint, timestamp: timestamp, context: .main, modifierFlags: modifierFlags)
    }

    private func beginPress(at containerPoint: CGPoint, timestamp: UInt64, context: GridContext, modifierFlags: CGEventFlags) -> Action {
        let pages = pages(for: context)
        let pointInPagesSuperlayer = containerLayer.convert(containerPoint, to: pages.scrollLayer.superlayer)
        if let pageIndex = pages.pageIndexOfIndicator(at: pointInPagesSuperlayer) {
            pointerTracking = .pagerIndicator(context: context, pageIndex: pageIndex)
            return .none
        }
        if let (pageGrid, gridPoint) = pages.pointInCurrentGrid(pointInPagesSuperlayer), let hit = pageGrid.item(at: gridPoint), hit.isOnIcon {
            hit.itemLayer.isDarkened = true
            pointerTracking = .icon(context: context, pageIndex: pages.currentPageIndex, itemIndex: hit.index, itemLayer: hit.itemLayer, startLocation: containerPoint, startTimestamp: timestamp)
            scheduleLongPress(on: hit.itemLayer, context: context, isShiftDown: modifierFlags.contains(.maskShift))
            return .none
        }
        pointerTracking = .background(context: context, startLocation: containerPoint, startScrollValue: pages.scrollValue, startTimestamp: timestamp, isDragging: false)
        return .none
    }

    /// A press held on an icon switches jiggle mode for the pages in front (15's `deletingTimer`,
    /// `sub_10006F06C`): the icon grows to 1.1 and keeps still until it is let go.
    private func scheduleLongPress(on itemLayer: SpringboardItemLayer, context: GridContext, isShiftDown: Bool) {
        cancelLongPress()
        longPressTask = Task { [weak self] in
            try? await Task.sleep(for: SpringboardJiggle.longPressDuration(isShiftDown: isShiftDown))
            guard !Task.isCancelled, let self else { return }
            self.longPressTask = nil
            guard case let .icon(_, _, _, pressedLayer, _, _) = self.pointerTracking, pressedLayer === itemLayer else { return }
            let pages = self.pages(for: context)
            pages.isJiggling.toggle()
            itemLayer.isMagnified = true
            itemLayer.isHeldStill = true
            self.longPressedItemLayer = itemLayer
        }
    }

    private func cancelLongPress() {
        longPressTask?.cancel()
        longPressTask = nil
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
            // A drag takes over the icon, held still and enlarged, whether or not its long press fired.
            cancelLongPress()
            longPressedItemLayer = nil
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
        case let .titleEditor(doubleClickedWord):
            if let folderPanel {
                dragInRenameField(to: folderPanel.pointInTitleEditor(containerPoint), doubleClickedWord: doubleClickedWord)
            }
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
            cancelLongPress()
            itemLayer.isDarkened = false
            if longPressedItemLayer === itemLayer {
                // 15 neither launched nor opened what a long press had switched jiggle mode on.
                longPressedItemLayer = nil
                itemLayer.isMagnified = false
                itemLayer.isHeldStill = false
                return .none
            }
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
                // Even in jiggle mode, as in 15.
                return launchAction(for: application, itemLayer: hit.itemLayer)
            case .folder(let folder):
                // 15 took jiggle mode from the main pages into the folder it opened, and the main pages
                // were still once it closed (`-[ECSBEventHandler leftMouseUp:inLayer:ofPage:]`, 15.5
                // `0x10006F408`).
                let isJiggling = pages.isJiggling
                pages.isJiggling = false
                openFolder(folder, from: hit.itemLayer)
                folderPanel?.pages.isJiggling = isJiggling
                return .none
            case .none:
                return .none
            }
        case let .background(context, startLocation, startScrollValue, startTimestamp, isDragging):
            guard isDragging else {
                guard context == .main else { return .none }
                let movement = hypot(containerPoint.x - startLocation.x, containerPoint.y - startLocation.y)
                guard movement < SpringboardPaging.dragThreshold else { return .none }
                // 15 ended jiggle mode on a click on the background, and otherwise closed, search or not
                // (`cancelActionWithEvent:sender:`).
                guard !mainPages.isJiggling else {
                    mainPages.isJiggling = false
                    return .none
                }
                return .dismiss(reason: "clicked outside the icons")
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
            // The press was the title's, so 15 started renaming wherever it was let go
            // (`-[ECSBGroup leftMouseUp:in:]`, 15.5 `0x1000A36F0`).
            if SpringboardPreferences.allowsRenamingFolders {
                startRenaming()
            }
            return .none
        case .none, .searchField, .titleEditor:
            return .none
        }
    }

    // MARK: - Scroll wheel and trackpad

    func handleScrollWheel(_ scrollWheel: SpringboardInputEvent.ScrollWheel, timestamp: UInt64) -> Action {
        guard !isAnimatingFolder, dragSession == nil else { return .none }
        pages(for: folderPanel == nil ? .main : .folder).handleScrollWheel(scrollWheel, timestamp: timestamp)
        return .none
    }

    /// A three-finger swipe turns the pages in front one page, as 15's pager did for the main pages and
    /// an open folder alike.
    func handleNavigationSwipe(_ navigationSwipe: SpringboardInputEvent.NavigationSwipe) -> Action {
        guard !isAnimatingFolder, dragSession == nil, let pageOffset = navigationSwipe.pageOffset else { return .none }
        frontPages.turn(toPageAt: frontPages.currentPageIndex + pageOffset)
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
