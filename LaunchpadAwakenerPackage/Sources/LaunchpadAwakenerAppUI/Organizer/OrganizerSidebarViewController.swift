import AppKit
import AppKitNavigation
import AppKitPlus
import LaunchpadAwakenerAppCore
import SnapKit
import UIFoundation

/// The organizer's sidebar: Launchpad's pages, each with its folders under it, all expanded. Selecting one
/// shows it in the list; dropping items on one moves them there.
final class OrganizerSidebarViewController: XiblessViewController<XiblessView>, NSOutlineViewDelegate {
    typealias Container = LaunchpadOrganizer.Container

    @UIBindable private var viewModel: LaunchpadOrganizerViewModel

    private let (scrollView, outlineView): (NSScrollView, NSOutlineView) = NSOutlineView.scrollableSingleColumnOutlineView()
    private var dataSource: OrganizerSidebarDataSource!

    private lazy var cellRegistration = NSOutlineView.CellRegistration<OrganizerSidebarCellView, Container> { [weak self] cell, _, _, container in
        guard let self, let layout = viewModel.layout else { return }
        var content = cell.defaultContentConfiguration()
        let count: Int
        switch container {
        case .page(let pageIdentifier):
            let page = layout.page(pageIdentifier)
            content.text = "Page \(page?.number ?? 0)"
            content.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: nil)
            count = page?.items.count ?? 0
        case .folder(let folderIdentifier):
            let folder = layout.folder(folderIdentifier)
            content.text = folder?.title ?? ""
            content.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            count = folder?.applications.count ?? 0
        }
        cell.contentConfiguration = content
        cell.accessories = [.badge(count: count)]
    }

    init(viewModel: LaunchpadOrganizerViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = true
        outlineView.registerForDraggedTypes([.organizerItem])
        outlineView.setDraggingSourceOperationMask([], forLocal: true)
        outlineView.delegate = self

        dataSource = OrganizerSidebarDataSource(outlineView: outlineView) { [weak self] outlineView, column, row, container in
            guard let self else { return NSView() }
            return outlineView.dequeueConfiguredReusableCellView(using: cellRegistration, ofColumn: column, forRow: row, item: container)
        }
        dataSource.viewModel = viewModel

        hierarchy {
            scrollView
        }
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        observe { [weak self] in
            guard let self else { return }
            apply(viewModel.layout)
        }
        outlineView.bind(
            selection: $viewModel.selectedContainer,
            row: { [weak self] container in self?.dataSource.row(forItemIdentifier: container) },
            itemIdentifier: { [weak self] row in self?.dataSource.itemIdentifier(forRow: row) }
        )
    }

    /// Shows `layout`'s pages and folders. Reloads rather than diffs: a folder renamed or a page that gained
    /// an item keeps its identifier, and only a reload redraws its title and count.
    private func apply(_ layout: LaunchpadOrganizer.Layout?) {
        var snapshot = NSDiffableDataSourceSectionSnapshot<Container>()
        for page in layout?.pages ?? [] {
            let pageContainer = Container.page(page.id)
            snapshot.append([pageContainer])
            snapshot.append(page.folders.map { Container.folder($0.id) }, to: pageContainer)
            snapshot.expand([pageContainer])
        }
        dataSource.applySnapshotUsingReloadData(snapshot)
        // A reload drops the selection, and the binding only selects again when the selection itself
        // changes; put it back.
        if let selectedContainer = viewModel.selectedContainer {
            let row = dataSource.row(forItemIdentifier: selectedContainer)
            if row >= 0 {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
            }
        }
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        // Pages stay expanded; there is nothing to collapse.
        false
    }
}

/// The sidebar's rows, and where drops on them go. Rows are never dragged themselves.
private final class OrganizerSidebarDataSource: NSOutlineViewDiffableDataSource<LaunchpadOrganizer.Container> {
    weak var viewModel: LaunchpadOrganizerViewModel?

    override func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        nil
    }

    override func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard dropOperation(info, onto: item) != nil else { return [] }
        // Always onto the row itself: the sidebar has no order of its own to insert into.
        outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    override func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let viewModel, let operation = dropOperation(info, onto: item) else { return false }
        Task {
            await viewModel.perform(operation)
        }
        return true
    }

    private func dropOperation(_ info: any NSDraggingInfo, onto item: Any?) -> LaunchpadOrganizerViewModel.DropOperation? {
        guard let viewModel, let item, let container = itemIdentifier(forOutlineViewItem: item) else { return nil }
        return viewModel.dropOperation(of: OrganizerPasteboard.draggedItems(in: info), onto: .container(container))
    }
}

/// A page or a folder in the sidebar. Its content comes from a list content configuration.
final class OrganizerSidebarCellView: NSTableCellView {}
