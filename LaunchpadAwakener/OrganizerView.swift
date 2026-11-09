import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LaunchpadAwakenerAppCore

/// The window for organizing the Launchpad layout: pages and folders on the left, what the selected one
/// holds on the right, and actions for every selected item at once.
struct OrganizerView: View {
    typealias Container = LaunchpadOrganizer.Container
    typealias ItemIdentifier = LaunchpadOrganizer.ItemIdentifier

    @Environment(LaunchpadOrganizer.self) private var organizer
    @Environment(PayloadInjectionCoordinator.self) private var injectionCoordinator

    @State private var selectedContainer: Container?
    /// Pages and folders shown before the current one, for Back.
    @State private var navigationHistory: [Container] = []
    /// Set while Back changes the selection, so that the change is not recorded as a new step.
    @State private var isNavigatingBack = false
    @State private var selectedItems: Set<ItemIdentifier> = []
    @State private var searchText = ""
    @State private var folderNaming: FolderNaming?
    @State private var folderBeingDissolved: LaunchpadOrganizer.Folder?
    @State private var categoryGroupsToConfirm: [LaunchpadOrganizer.CategoryGroup]?

    /// How often the window asks the Dock whether the layout changed while it is open.
    private static let refreshInterval = Duration.seconds(3)

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            detail
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Applications")
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .frame(minWidth: 760, minHeight: 480)
        .task {
            while !Task.isCancelled {
                await injectionCoordinator.refreshState()
                await organizer.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .onChange(of: organizer.layout) { _, layout in
            keepSelectionValid(in: layout)
        }
        .onChange(of: selectedContainer) { previousContainer, _ in
            recordNavigation(from: previousContainer)
        }
        .sheet(item: $folderNaming) { naming in
            FolderNameSheet(naming: naming) { name in
                Task { await finishNaming(naming, name: name) }
            }
        }
        .confirmationDialog(
            "Dissolve “\(folderBeingDissolved?.title ?? "")”?",
            isPresented: isDissolvingFolder,
            presenting: folderBeingDissolved
        ) { folder in
            Button("Dissolve", role: .destructive) {
                Task { await organizer.dissolveFolder(folder.id) }
            }
        } message: { _ in
            Text("Its applications take its place on the page.")
        }
        .sheet(item: categoryGroupsSheet) { sheet in
            CategoryGroupingSheet(groups: sheet.groups) {
                Task { await organizer.groupByCategory(sheet.groups) }
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if let layout = organizer.layout {
            List(selection: $selectedContainer) {
                ForEach(layout.pages) { page in
                    Label("Page \(page.number)", systemImage: "square.grid.3x3")
                        .badge(page.items.count)
                        .tag(Container.page(page.id))
                        .dropDestination(for: String.self) { payloads, _ in
                            drop(payloads, onto: .page(page.id))
                        }
                    ForEach(page.folders) { folder in
                        Label(folder.title, systemImage: "folder")
                            .badge(folder.applications.count)
                            .padding(.leading, 14)
                            .tag(Container.folder(folder.id))
                            .dropDestination(for: String.self) { payloads, _ in
                                drop(payloads, onto: .folder(folder.id))
                            }
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            Color.clear
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch organizer.availability {
        case .loading where organizer.layout == nil:
            ProgressView("Reading the layout from the Dock…")
        case .unavailable(let reason):
            ContentUnavailableView {
                Label("Nothing to Organize", systemImage: "square.grid.3x3.slash")
            } description: {
                Text(reason)
            } actions: {
                if injectionCoordinator.residentPayloads.first?.isStale == true {
                    Button("Restart Dock") {
                        injectionCoordinator.restartTargets()
                    }
                    .disabled(injectionCoordinator.isBusy)
                }
            }
        default:
            if let layout = organizer.layout {
                itemList(in: layout)
            }
        }
    }

    private func itemList(in layout: LaunchpadOrganizer.Layout) -> some View {
        let rows = rows(in: layout)
        return List(selection: $selectedItems) {
            ForEach(rows) { row in
                ItemRow(row: row)
                    .tag(row.item.id)
                    .draggable(dragPayload(startingWith: row.item.id))
                    .dropDestination(for: String.self) { payloads, _ in
                        drop(payloads, onto: row, in: layout)
                    }
            }
        }
        .contextMenu(forSelectionType: ItemIdentifier.self) { itemIdentifiers in
            actionMenuItems(for: itemIdentifiers, in: layout)
        } primaryAction: { itemIdentifiers in
            open(itemIdentifiers, in: layout)
        }
        .dropDestination(for: String.self) { payloads, _ in
            guard isSearching == false, let selectedContainer else { return false }
            return drop(payloads, onto: selectedContainer)
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(isSearching ? "No Matches" : "Empty", systemImage: isSearching ? "magnifyingglass" : "tray")
            }
        }
        .navigationTitle(title(of: selectedContainer, in: layout))
        .navigationSubtitle(isSearching ? "Search results" : "\(rows.count) item\(rows.count == 1 ? "" : "s")")
    }

    /// One line of the list: an item, and when searching, where it is.
    struct Row: Identifiable {
        let item: LaunchpadOrganizer.Item
        let location: String?

        var id: ItemIdentifier { item.id }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func rows(in layout: LaunchpadOrganizer.Layout) -> [Row] {
        if isSearching {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            return layout.applications
                .filter { $0.title.localizedStandardContains(query) || $0.bundleIdentifier.localizedStandardContains(query) }
                .map { application in
                    Row(item: .application(application), location: location(of: application.id, in: layout))
                }
        }
        guard let selectedContainer else { return [] }
        return layout.items(in: selectedContainer).map { Row(item: $0, location: nil) }
    }

    private func location(of itemIdentifier: ItemIdentifier, in layout: LaunchpadOrganizer.Layout) -> String {
        let pageName = layout.page(containing: itemIdentifier).map { "Page \($0.number)" } ?? ""
        guard let folder = layout.folder(containing: itemIdentifier) else { return pageName }
        return "\(pageName) › \(folder.title)"
    }

    private func title(of container: Container?, in layout: LaunchpadOrganizer.Layout) -> String {
        switch container {
        case .page(let pageIdentifier): "Page \(layout.page(pageIdentifier)?.number ?? 0)"
        case .folder(let folderIdentifier): layout.folder(folderIdentifier)?.title ?? "Folder"
        case nil: "Organize Launchpad"
        }
    }

    // MARK: - Actions

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .help("Back to the page or folder shown before")
            .keyboardShortcut("[", modifiers: .command)
            .disabled(navigationHistory.isEmpty)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let layout = organizer.layout {
                Menu {
                    moveMenuItems(for: selectedItems, in: layout)
                } label: {
                    Label("Move To", systemImage: "arrow.right.square")
                }
                .help("Move the selected items to another page or into a folder")
                .disabled(selectedItems.isEmpty || organizer.isApplying)

                Button {
                    beginNewFolder(from: selectedItems)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .help("Put the selected applications into a new folder")
                .disabled(!canMakeFolder(from: selectedItems, in: layout))

                Button {
                    Task { await organizer.moveOutOfFolders(selectedItems) }
                } label: {
                    Label("Move Out of Folder", systemImage: "arrow.up.right.square")
                }
                .help("Move the selected applications out of their folders, to the end of the folder's page")
                .disabled(!isAnyInFolder(selectedItems, in: layout) || organizer.isApplying)

                Menu {
                    if let selectedContainer, !isSearching {
                        Button("Sort by Name") {
                            Task { await organizer.sortByName(selectedContainer) }
                        }
                    }
                    if case .folder(let folderIdentifier) = selectedContainer, let folder = layout.folder(folderIdentifier) {
                        Divider()
                        Button("Rename Folder…") {
                            folderNaming = .rename(folder)
                        }
                        Button("Dissolve Folder…") {
                            folderBeingDissolved = folder
                        }
                    }
                    Divider()
                    Button("Group by Category…") {
                        categoryGroupsToConfirm = organizer.categoryGroups()
                    }
                } label: {
                    Label("Arrange", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort, rename or dissolve the selected folder, or group applications by category")
                .disabled(organizer.isApplying)
            }
        }
    }

    @ViewBuilder
    private func moveMenuItems(for itemIdentifiers: Set<ItemIdentifier>, in layout: LaunchpadOrganizer.Layout) -> some View {
        ForEach(layout.pages) { page in
            Button("Page \(page.number)") {
                Task { await organizer.move(itemIdentifiers, to: .page(page.id)) }
            }
        }
        Button("New Page") {
            Task { await organizer.move(itemIdentifiers, to: .newPage) }
        }
        let folders = layout.folders
        if !folders.isEmpty {
            Divider()
            // A folder cannot go into a folder.
            let isAllApplications = layout.areAllApplications(itemIdentifiers)
            ForEach(folders) { folder in
                Button(folder.title) {
                    Task { await organizer.move(itemIdentifiers, to: .folder(folder.id)) }
                }
                .disabled(!isAllApplications)
            }
        }
    }

    /// The right-click menu, for the rows it was opened on: the selection when the clicked row is part of
    /// it, else that row.
    @ViewBuilder
    private func actionMenuItems(for targets: Set<ItemIdentifier>, in layout: LaunchpadOrganizer.Layout) -> some View {
        if targets.isEmpty {
            EmptyView()
        } else {
            itemMenuItems(for: targets, in: layout)
        }
    }

    @ViewBuilder
    private func itemMenuItems(for targets: Set<ItemIdentifier>, in layout: LaunchpadOrganizer.Layout) -> some View {
        Menu("Move To") {
            moveMenuItems(for: targets, in: layout)
        }
        Button("New Folder with Selection…") {
            beginNewFolder(from: targets)
        }
        .disabled(!canMakeFolder(from: targets, in: layout))
        if isAnyInFolder(targets, in: layout) {
            Button("Move Out of Folder") {
                Task { await organizer.moveOutOfFolders(targets) }
            }
        }
        if targets.count == 1, let onlyTarget = targets.first, let folder = layout.folder(onlyTarget) {
            Divider()
            Button("Open Folder") {
                show(.folder(folder.id))
            }
            Button("Rename Folder…") {
                folderNaming = .rename(folder)
            }
            Button("Dissolve Folder…") {
                folderBeingDissolved = folder
            }
        }
    }

    private func canMakeFolder(from itemIdentifiers: Set<ItemIdentifier>, in layout: LaunchpadOrganizer.Layout) -> Bool {
        !organizer.isApplying && itemIdentifiers.count >= 2 && layout.areAllApplications(itemIdentifiers)
    }

    private func isAnyInFolder(_ itemIdentifiers: Set<ItemIdentifier>, in layout: LaunchpadOrganizer.Layout) -> Bool {
        itemIdentifiers.contains { layout.folder(containing: $0) != nil }
    }

    private func beginNewFolder(from itemIdentifiers: Set<ItemIdentifier>) {
        folderNaming = .new(itemIdentifiers, suggestedName: organizer.suggestedFolderName(for: itemIdentifiers))
    }

    private func finishNaming(_ naming: FolderNaming, name: String) async {
        switch naming {
        case .new(let itemIdentifiers, _):
            await organizer.makeFolder(of: itemIdentifiers, titled: name)
            selectedItems = []
        case .rename(let folder):
            await organizer.renameFolder(folder.id, to: name)
        }
    }

    // MARK: - Navigating

    /// Double-click or Return: a folder opens; an application found by searching is shown where it is.
    private func open(_ itemIdentifiers: Set<ItemIdentifier>, in layout: LaunchpadOrganizer.Layout) {
        guard itemIdentifiers.count == 1, let itemIdentifier = itemIdentifiers.first else { return }
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

    private func show(_ container: Container) {
        searchText = ""
        selectedContainer = container
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

    private static let navigationHistoryLimit = 50

    /// Back to the last page or folder shown that is still in the layout.
    private func goBack() {
        guard let layout = organizer.layout else { return }
        while let previousContainer = navigationHistory.popLast() {
            if exists(previousContainer, in: layout) {
                isNavigatingBack = true
                searchText = ""
                selectedContainer = previousContainer
                selectedItems = []
                return
            }
        }
    }

    private func exists(_ container: Container, in layout: LaunchpadOrganizer.Layout) -> Bool {
        switch container {
        case .page(let pageIdentifier): layout.page(pageIdentifier) != nil
        case .folder(let folderIdentifier): layout.folder(folderIdentifier) != nil
        }
    }

    // MARK: - Dragging

    /// Items dragged within this window travel as text with this prefix, followed by their identifiers.
    private static let dragPayloadPrefix = "launchpad-organizer:"

    /// The whole selection when the dragged row is part of it, else just that row.
    private func dragPayload(startingWith itemIdentifier: ItemIdentifier) -> String {
        let draggedItems = selectedItems.contains(itemIdentifier) ? selectedItems : [itemIdentifier]
        return Self.dragPayloadPrefix + draggedItems.map(\.description).joined(separator: ",")
    }

    private static func draggedItems(in payloads: [String]) -> Set<ItemIdentifier> {
        Set(payloads.flatMap { payload -> [ItemIdentifier] in
            guard payload.hasPrefix(dragPayloadPrefix) else { return [] }
            return payload.dropFirst(dragPayloadPrefix.count).split(separator: ",").compactMap { Int64($0).map(ItemIdentifier.init(rawValue:)) }
        })
    }

    /// Dropped on a page or a folder in the sidebar, or on the list's empty space: moved there.
    private func drop(_ payloads: [String], onto container: Container) -> Bool {
        let draggedItems = Self.draggedItems(in: payloads)
        guard !draggedItems.isEmpty, !organizer.isApplying else { return false }
        let destination: LaunchpadOrganizer.MoveDestination = switch container {
        case .page(let pageIdentifier): .page(pageIdentifier)
        case .folder(let folderIdentifier): .folder(folderIdentifier)
        }
        Task { await organizer.move(draggedItems, to: destination) }
        return true
    }

    /// Dropped on a row: into it when it is a folder, else before it — reordering when everything
    /// dragged is already in the container shown.
    private func drop(_ payloads: [String], onto row: Row, in layout: LaunchpadOrganizer.Layout) -> Bool {
        let draggedItems = Self.draggedItems(in: payloads)
        guard !draggedItems.isEmpty, !draggedItems.contains(row.item.id), !organizer.isApplying else { return false }
        if case .folder(let folder) = row.item {
            Task { await organizer.move(draggedItems, to: .folder(folder.id)) }
            return true
        }
        guard !isSearching, let selectedContainer else { return false }
        let currentOrder = layout.items(in: selectedContainer).map(\.id)
        guard draggedItems.isSubset(of: Set(currentOrder)) else {
            return drop(payloads, onto: selectedContainer)
        }
        var newOrder = currentOrder.filter { !draggedItems.contains($0) }
        let insertionIndex = newOrder.firstIndex(of: row.item.id) ?? newOrder.count
        newOrder.insert(contentsOf: currentOrder.filter(draggedItems.contains), at: insertionIndex)
        Task { await organizer.arrange(selectedContainer, inOrder: newOrder) }
        return true
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBar: some View {
        if organizer.isApplying || organizer.lastErrorDescription != nil {
            HStack(spacing: 8) {
                if organizer.isApplying {
                    ProgressView().controlSize(.small)
                    Text("Updating Launchpad…")
                        .foregroundStyle(.secondary)
                } else if let lastErrorDescription = organizer.lastErrorDescription {
                    Label(lastErrorDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    // MARK: - Selection

    /// Drops selected items the layout no longer has, and falls back to the first page when the selected
    /// page or folder went away.
    private func keepSelectionValid(in layout: LaunchpadOrganizer.Layout?) {
        guard let layout else {
            selectedItems = []
            return
        }
        let existingItems = Set(layout.applications.map(\.id)).union(layout.pages.flatMap(\.items).map(\.id))
        selectedItems.formIntersection(existingItems)
        let containerExists = selectedContainer.map { exists($0, in: layout) } ?? false
        if !containerExists {
            selectedContainer = layout.pages.first.map { .page($0.id) }
        }
    }

    // MARK: - Presentation state

    private var isDissolvingFolder: Binding<Bool> {
        Binding(get: { folderBeingDissolved != nil }, set: { if !$0 { folderBeingDissolved = nil } })
    }

    private var categoryGroupsSheet: Binding<CategoryGroupsSheet?> {
        Binding(
            get: { categoryGroupsToConfirm.map(CategoryGroupsSheet.init) },
            set: { if $0 == nil { categoryGroupsToConfirm = nil } }
        )
    }
}

/// Naming a folder: a new one for selected applications, or an existing one.
enum FolderNaming: Identifiable {
    case new(Set<LaunchpadOrganizer.ItemIdentifier>, suggestedName: String)
    case rename(LaunchpadOrganizer.Folder)

    var id: String {
        switch self {
        case .new(let itemIdentifiers, _): "new " + itemIdentifiers.map(\.description).sorted().joined(separator: ",")
        case .rename(let folder): "rename \(folder.id)"
        }
    }

    var isNew: Bool {
        if case .new = self { true } else { false }
    }

    var title: String {
        switch self {
        case .new: "New Folder"
        case .rename: "Rename Folder"
        }
    }

    var initialName: String {
        switch self {
        case .new(_, let suggestedName): suggestedName
        case .rename(let folder): folder.title
        }
    }
}

/// Asks for a folder's name.
private struct FolderNameSheet: View {
    let naming: FolderNaming
    let commit: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(naming: FolderNaming, commit: @escaping (String) -> Void) {
        self.naming = naming
        self.commit = commit
        _name = State(initialValue: naming.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(naming.title)
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(naming.isNew ? "Create" : "Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        commit(name)
        dismiss()
    }
}

private struct CategoryGroupsSheet: Identifiable {
    let groups: [LaunchpadOrganizer.CategoryGroup]
    var id: [String] { groups.map(\.id) }
}

/// What grouping by category would do, shown before it is done.
private struct CategoryGroupingSheet: View {
    let groups: [LaunchpadOrganizer.CategoryGroup]
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Group by Category")
                .font(.headline)
            if groups.isEmpty {
                Text("No application outside a folder shares a category with another, or with a folder of that name.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Applications outside folders go into folders named after their App Store category.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List(groups) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.existingFolder == nil ? "New folder “\(group.title)”" : "Into “\(group.title)”")
                            .font(.body.weight(.medium))
                        Text(group.applications.map(\.title).joined(separator: ", "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 220)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Group") {
                    confirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groups.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// One application or folder in the list.
private struct ItemRow: View {
    let row: OrganizerView.Row

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.item.title)
                if let location = row.location {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if case .folder(let folder) = row.item {
                Text("\(folder.applications.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var icon: some View {
        switch row.item {
        case .application(let application):
            Image(nsImage: ApplicationIconCache.shared.icon(for: application.bundleURL))
                .resizable()
                .interpolation(.high)
        case .folder:
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }
}

/// Icons of the listed applications, read once per bundle path.
@MainActor
private final class ApplicationIconCache {
    static let shared = ApplicationIconCache()

    private let icons = NSCache<NSString, NSImage>()

    func icon(for bundleURL: URL?) -> NSImage {
        guard let bundleURL else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        if let icon = icons.object(forKey: bundleURL.path as NSString) {
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icons.setObject(icon, forKey: bundleURL.path as NSString)
        return icon
    }
}
