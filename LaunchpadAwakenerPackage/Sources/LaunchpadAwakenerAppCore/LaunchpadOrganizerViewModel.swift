import Foundation

/// The organizer window's state: which page or folder is shown, what is selected, where Back goes, what
/// a search finds, and what a drop does.
///
/// The window lays this out and forwards the user's actions; every rule about what an action means is
/// here, where it can be tested without a window. Edits go through this model rather than straight to
/// the organizer, so that the selection is put right after each one.
@MainActor
@Observable
public final class LaunchpadOrganizerViewModel {
    public typealias Container = LaunchpadOrganizer.Container
    public typealias ItemIdentifier = LaunchpadOrganizer.ItemIdentifier

    /// One line of the list: an item, and when searching, where it is.
    public struct Row: Hashable, Sendable, Identifiable {
        public let item: LaunchpadOrganizer.Item
        /// "Page 2 › Tools" for a search result; nil when the list shows one page or folder.
        public let location: String?

        public var id: ItemIdentifier { item.id }
    }

    /// Naming a folder: a new one for selected applications, or an existing one.
    public enum FolderNaming: Hashable, Sendable, Identifiable {
        case new(Set<ItemIdentifier>, suggestedName: String)
        case rename(LaunchpadOrganizer.Folder)

        public var id: String {
            switch self {
            case .new(let itemIdentifiers, _): "new " + itemIdentifiers.map(\.description).sorted().joined(separator: ",")
            case .rename(let folder): "rename \(folder.id)"
            }
        }

        public var title: String {
            switch self {
            case .new: "New Folder"
            case .rename: "Rename Folder"
            }
        }

        /// The title of the button that commits the name.
        public var confirmationTitle: String {
            switch self {
            case .new: "Create"
            case .rename: "Rename"
            }
        }

        public var initialName: String {
            switch self {
            case .new(_, let suggestedName): suggestedName
            case .rename(let folder): folder.title
            }
        }
    }

    /// What grouping by App Store category would do, shown for the user to confirm.
    public struct CategoryGrouping: Hashable, Sendable, Identifiable {
        public let groups: [LaunchpadOrganizer.CategoryGroup]

        public var id: [String] { groups.map(\.id) }
    }

    /// Where dragged items are dropped.
    public enum DropTarget: Hashable, Sendable {
        /// A page or a folder in the sidebar.
        case container(Container)
        /// A row of the list.
        case row(ItemIdentifier)
        /// The list's empty space below its rows.
        case listBackground
    }

    /// What a drop does.
    public enum DropOperation: Hashable, Sendable {
        case move(Set<ItemIdentifier>, to: LaunchpadOrganizer.MoveDestination)
        /// Puts the page's items, or the folder's applications, in a new order.
        case arrange(Container, inOrder: [ItemIdentifier])
    }

    public let organizer: LaunchpadOrganizer

    /// The page or folder the sidebar has selected. Changing it records the previous one for Back,
    /// unless Back is what changed it.
    public var selectedContainer: Container? {
        didSet {
            recordNavigation(from: oldValue)
        }
    }

    public var selectedItems: Set<ItemIdentifier> = []

    public var searchText = ""

    /// Set while a folder's name is being asked for.
    public var folderNaming: FolderNaming?

    /// Set while dissolving a folder waits for confirmation.
    public var folderBeingDissolved: LaunchpadOrganizer.Folder?

    /// Set while grouping by category waits for confirmation.
    public var categoryGrouping: CategoryGrouping?

    /// Pages and folders shown before the current one, most recent last.
    private var navigationHistory: [Container] = []

    /// Set while Back changes the selection, so that the change is not recorded as a new step.
    @ObservationIgnored
    private var isNavigatingBack = false

    private static let navigationHistoryLimit = 50

    public init(organizer: LaunchpadOrganizer) {
        self.organizer = organizer
    }

    // MARK: - What is shown

    public var layout: LaunchpadOrganizer.Layout? {
        organizer.layout
    }

    public var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The list: the selected page's or folder's items, or, while searching, every application whose name
    /// or bundle identifier matches, with where it is.
    public var rows: [Row] {
        guard let layout else { return [] }
        if isSearching {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            return layout.applications
                .filter { $0.title.localizedStandardContains(query) || $0.bundleIdentifier.localizedStandardContains(query) }
                .map { application in
                    Row(item: .application(application), location: Self.location(of: application.id, in: layout))
                }
        }
        guard let selectedContainer else { return [] }
        return layout.items(in: selectedContainer).map { Row(item: $0, location: nil) }
    }

    /// The window's title: the page or folder shown.
    public var title: String {
        guard let layout else { return "Organize Launchpad" }
        switch selectedContainer {
        case .page(let pageIdentifier): return "Page \(layout.page(pageIdentifier)?.number ?? 0)"
        case .folder(let folderIdentifier): return layout.folder(folderIdentifier)?.title ?? "Folder"
        case nil: return "Organize Launchpad"
        }
    }

    /// The window's subtitle: how many items the list holds, or that it shows search results.
    public var subtitle: String {
        if isSearching {
            return "Search results"
        }
        let rowCount = rows.count
        return "\(rowCount) item\(rowCount == 1 ? "" : "s")"
    }

    private static func location(of itemIdentifier: ItemIdentifier, in layout: LaunchpadOrganizer.Layout) -> String {
        let pageName = layout.page(containing: itemIdentifier).map { "Page \($0.number)" } ?? ""
        guard let folder = layout.folder(containing: itemIdentifier) else { return pageName }
        return "\(pageName) › \(folder.title)"
    }

    // MARK: - Reading

    /// Reads the layout again if it changed, then puts the selection right. The window calls this every
    /// few seconds while it is open.
    public func refresh() async {
        await organizer.refresh()
        layoutDidChange()
    }

    /// Drops selected items the layout no longer has, and falls back to the first page when the selected
    /// page or folder went away.
    ///
    /// Assigns only what actually changes: every assignment to an observed property notifies observers,
    /// equal value or not.
    func layoutDidChange() {
        guard let layout else {
            if !selectedItems.isEmpty {
                selectedItems = []
            }
            return
        }
        let existingItems = Set(layout.applications.map(\.id)).union(layout.pages.flatMap(\.items).map(\.id))
        let validSelection = selectedItems.intersection(existingItems)
        if validSelection != selectedItems {
            selectedItems = validSelection
        }
        let containerExists = selectedContainer.map { Self.exists($0, in: layout) } ?? false
        if !containerExists {
            selectedContainer = layout.pages.first.map { .page($0.id) }
        }
    }

    private static func exists(_ container: Container, in layout: LaunchpadOrganizer.Layout) -> Bool {
        switch container {
        case .page(let pageIdentifier): layout.page(pageIdentifier) != nil
        case .folder(let folderIdentifier): layout.folder(folderIdentifier) != nil
        }
    }

    // MARK: - Navigating

    public var canGoBack: Bool {
        !navigationHistory.isEmpty
    }

    /// Shows a page or folder, leaving any search.
    public func show(_ container: Container) {
        searchText = ""
        selectedContainer = container
    }

    /// Back to the last page or folder shown that is still in the layout.
    public func goBack() {
        guard let layout else { return }
        while let previousContainer = navigationHistory.popLast() {
            if Self.exists(previousContainer, in: layout) {
                isNavigatingBack = true
                searchText = ""
                selectedContainer = previousContainer
                selectedItems = []
                return
            }
        }
    }

    /// Double-click or Return: a folder opens; an application found by searching is shown where it is.
    public func open(_ itemIdentifiers: Set<ItemIdentifier>) {
        guard let layout, itemIdentifiers.count == 1, let itemIdentifier = itemIdentifiers.first else { return }
        if layout.folder(itemIdentifier) != nil {
            show(.folder(itemIdentifier))
            selectedItems = []
            return
        }
        guard isSearching else { return }
        if let folder = layout.folder(containing: itemIdentifier) {
            show(.folder(folder.id))
        } else if let page = layout.page(containing: itemIdentifier) {
            show(.page(page.id))
        }
        selectedItems = [itemIdentifier]
    }

    private func recordNavigation(from previousContainer: Container?) {
        if isNavigatingBack {
            isNavigatingBack = false
            return
        }
        guard let previousContainer, previousContainer != selectedContainer else { return }
        navigationHistory.append(previousContainer)
        if navigationHistory.count > Self.navigationHistoryLimit {
            navigationHistory.removeFirst()
        }
    }

    // MARK: - Acting on items

    /// The items an action on one row applies to: the whole selection when the row is part of it, else
    /// that row alone. Dragging a row and its context menu both follow this.
    public func targetItems(forRow itemIdentifier: ItemIdentifier) -> Set<ItemIdentifier> {
        selectedItems.contains(itemIdentifier) ? selectedItems : [itemIdentifier]
    }

    /// Whether `itemIdentifiers` can make a new folder: two applications or more, and no edit under way.
    public func canMakeFolder(from itemIdentifiers: Set<ItemIdentifier>) -> Bool {
        guard let layout else { return false }
        return !organizer.isApplying && itemIdentifiers.count >= 2 && layout.areAllApplications(itemIdentifiers)
    }

    /// Whether any of `itemIdentifiers` sits in a folder.
    public func isAnyInFolder(_ itemIdentifiers: Set<ItemIdentifier>) -> Bool {
        guard let layout else { return false }
        return itemIdentifiers.contains { layout.folder(containing: $0) != nil }
    }

    /// Whether `itemIdentifiers` can go into a folder: a folder cannot go into a folder.
    public func canMoveIntoFolder(_ itemIdentifiers: Set<ItemIdentifier>) -> Bool {
        layout?.areAllApplications(itemIdentifiers) ?? false
    }

    public func move(_ itemIdentifiers: Set<ItemIdentifier>, to destination: LaunchpadOrganizer.MoveDestination) async {
        await organizer.move(itemIdentifiers, to: destination)
        layoutDidChange()
    }

    public func moveOutOfFolders(_ itemIdentifiers: Set<ItemIdentifier>) async {
        await organizer.moveOutOfFolders(itemIdentifiers)
        layoutDidChange()
    }

    public func sortByName(_ container: Container) async {
        await organizer.sortByName(container)
        layoutDidChange()
    }

    /// Asks for the name of a new folder of `itemIdentifiers`, suggesting their App Store category.
    public func beginNewFolder(from itemIdentifiers: Set<ItemIdentifier>) {
        folderNaming = .new(itemIdentifiers, suggestedName: organizer.suggestedFolderName(for: itemIdentifiers))
    }

    public func beginRenaming(_ folder: LaunchpadOrganizer.Folder) {
        folderNaming = .rename(folder)
    }

    /// Commits a name asked for by ``beginNewFolder(from:)`` or ``beginRenaming(_:)``. A new folder takes
    /// its applications out of the selection, which no longer lists them.
    public func finishNaming(_ naming: FolderNaming, name: String) async {
        switch naming {
        case .new(let itemIdentifiers, _):
            await organizer.makeFolder(of: itemIdentifiers, titled: name)
            selectedItems = []
        case .rename(let folder):
            await organizer.renameFolder(folder.id, to: name)
        }
        layoutDidChange()
    }

    public func beginDissolving(_ folder: LaunchpadOrganizer.Folder) {
        folderBeingDissolved = folder
    }

    public func dissolve(_ folder: LaunchpadOrganizer.Folder) async {
        await organizer.dissolveFolder(folder.id)
        layoutDidChange()
    }

    /// Works out what grouping by category would do, for the user to confirm.
    public func beginGroupingByCategory() {
        categoryGrouping = CategoryGrouping(groups: organizer.categoryGroups())
    }

    public func groupByCategory(_ grouping: CategoryGrouping) async {
        await organizer.groupByCategory(grouping.groups)
        layoutDidChange()
    }

    // MARK: - Dragging

    /// What dropping `draggedItems` on `target` does; nil when the drop is refused.
    ///
    /// Dropped on a page or a folder in the sidebar, or on the list's empty space, the items move there.
    /// Dropped on a row, they go into it when it is a folder; else they go before it — reordering when
    /// everything dragged is already in the page or folder shown, moving there otherwise.
    public func dropOperation(of draggedItems: Set<ItemIdentifier>, onto target: DropTarget) -> DropOperation? {
        guard !draggedItems.isEmpty, !organizer.isApplying, let layout else { return nil }
        switch target {
        case .container(let container):
            return .move(draggedItems, to: Self.destination(container))
        case .listBackground:
            guard !isSearching, let selectedContainer else { return nil }
            return .move(draggedItems, to: Self.destination(selectedContainer))
        case .row(let rowItem):
            guard !draggedItems.contains(rowItem) else { return nil }
            if layout.folder(rowItem) != nil {
                return .move(draggedItems, to: .folder(rowItem))
            }
            guard !isSearching, let selectedContainer else { return nil }
            let currentOrder = layout.items(in: selectedContainer).map(\.id)
            guard draggedItems.isSubset(of: Set(currentOrder)) else {
                return .move(draggedItems, to: Self.destination(selectedContainer))
            }
            var newOrder = currentOrder.filter { !draggedItems.contains($0) }
            let insertionIndex = newOrder.firstIndex(of: rowItem) ?? newOrder.count
            newOrder.insert(contentsOf: currentOrder.filter(draggedItems.contains), at: insertionIndex)
            return .arrange(selectedContainer, inOrder: newOrder)
        }
    }

    public func perform(_ operation: DropOperation) async {
        switch operation {
        case .move(let itemIdentifiers, let destination):
            await organizer.move(itemIdentifiers, to: destination)
        case .arrange(let container, let order):
            await organizer.arrange(container, inOrder: order)
        }
        layoutDidChange()
    }

    private static func destination(_ container: Container) -> LaunchpadOrganizer.MoveDestination {
        switch container {
        case .page(let pageIdentifier): .page(pageIdentifier)
        case .folder(let folderIdentifier): .folder(folderIdentifier)
        }
    }
}
