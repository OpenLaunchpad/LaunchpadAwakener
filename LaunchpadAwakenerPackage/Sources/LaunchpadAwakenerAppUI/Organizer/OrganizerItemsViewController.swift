import AppKit
import AppKitNavigation
import AppKitPlus
import LaunchpadAwakenerAppCore
import SnapKit
import UIFoundation

/// The organizer's list: the selected page's or folder's items, or search results with where each one is.
///
/// Rows can be selected several at a time, dragged into a new order, onto a folder's row or onto the
/// sidebar, opened with a double-click or Return, and acted on from their context menu. The list says
/// when there is nothing to show, and why.
final class OrganizerItemsViewController: XiblessViewController<XiblessView>, NSTableViewDelegate, NSMenuDelegate {
    typealias Row = LaunchpadOrganizerViewModel.Row

    @UIBindable private var viewModel: LaunchpadOrganizerViewModel
    private let injectionCoordinator: PayloadInjectionCoordinator

    private let (scrollView, tableView): (NSScrollView, OrganizerTableView) = NSTableView.scrollableSingleColumnTableView()
    private var dataSource: OrganizerItemsDataSource!
    private let statusBar = OrganizerStatusBarView()
    /// Set while the list selects rows to match the view model, so the change is not written back.
    private var isMatchingSelection = false

    private lazy var cellRegistration = NSTableView.CellRegistration<OrganizerItemCellView, Row> { cell, _, _, row in
        var content = cell.defaultContentConfiguration()
        content.text = row.item.title
        content.secondaryText = row.location
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 4, bottom: 5, trailing: 8)
        content.imageProperties.maximumSize = NSSize(width: OrganizerItemCellView.iconSize, height: OrganizerItemCellView.iconSize)
        content.imageProperties.reservedLayoutSize = NSSize(width: OrganizerItemCellView.iconSize, height: OrganizerItemCellView.iconSize)
        switch row.item {
        case .application(let application):
            content.image = ApplicationIconCache.shared.icon(for: application.bundleURL)
            cell.accessories = []
        case .folder(let folder):
            content.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: OrganizerItemCellView.iconSize * 0.75, weight: .regular))
            content.imageProperties.tintColor = .secondaryLabelColor
            cell.accessories = [.label(text: "\(folder.applications.count)", options: .init(tintColor: .secondaryLabelColor))]
        }
        cell.contentConfiguration = content
    }

    private lazy var rowRegistration = NSTableView.RowRegistration<OrganizerItemRowView, Row> { [weak self] rowView, row, _ in
        rowView.showsSeparator = row < (self?.tableView.numberOfRows ?? 0) - 1
    }

    init(viewModel: LaunchpadOrganizerViewModel, injectionCoordinator: PayloadInjectionCoordinator) {
        self.viewModel = viewModel
        self.injectionCoordinator = injectionCoordinator
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.style = .inset
        tableView.allowsMultipleSelection = true
        tableView.usesAutomaticRowHeights = true
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow(_:))
        tableView.openSelection = { [weak self] in
            guard let self else { return }
            viewModel.open(viewModel.selectedItems)
        }
        tableView.draggingDestinationFeedbackStyle = .regular
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu

        dataSource = OrganizerItemsDataSource(tableView: tableView) { [weak self] tableView, column, row, item in
            guard let self else { return NSView() }
            return tableView.dequeueConfiguredReusableCellView(using: cellRegistration, ofColumn: column, forRow: row, item: item)
        }
        dataSource.rowViewProvider = { [weak self] tableView, row, item in
            guard let self, let item = item as? Row else { return NSTableRowView() }
            return tableView.dequeueConfiguredReusableRowView(using: rowRegistration, forRow: row, item: item)
        }
        dataSource.viewModel = viewModel
        var reorderingHandlers = OrganizerItemsDataSource.ReorderingHandlers()
        reorderingHandlers.canReorderItem = { [weak viewModel] _ in
            viewModel?.canReorder ?? false
        }
        reorderingHandlers.didReorder = { [weak self] transaction in
            self?.commitReorder(to: transaction.finalSnapshot.itemIdentifiers.map(\.id))
        }
        dataSource.reorderingHandlers = reorderingHandlers
        // The reorder data source registers its own type; folder rows read the identifiers in this one.
        tableView.registerForDraggedTypes(tableView.registeredDraggedTypes + [.organizerItem])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        hierarchy {
            scrollView
            statusBar
        }
        scrollView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(statusBar.snp.top)
        }
        statusBar.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
        }

        observeState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // On macOS 27 a click on a table does not make it the first responder; start with the list.
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: - Following the view model

    private func observeState() {
        observe { [weak self] in
            guard let self else { return }
            show(viewModel.rows, selecting: viewModel.selectedItems)
        }

        observe { [weak self] in
            guard let self else { return }
            scrollView.contentUnavailableConfiguration = contentUnavailableConfiguration()
        }

        observe { [weak self] in
            guard let self else { return }
            statusBar.show(isApplying: viewModel.organizer.isApplying, errorDescription: viewModel.organizer.lastErrorDescription)
        }
    }

    private func show(_ rows: [Row], selecting selectedItems: Set<LaunchpadOrganizer.ItemIdentifier>) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
        updateSeparators()

        let selectedRows = IndexSet(rows.indices.filter { selectedItems.contains(rows[$0].id) })
        guard selectedRows != tableView.selectedRowIndexes else { return }
        isMatchingSelection = true
        tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        isMatchingSelection = false
    }

    /// A hairline under every row but the last; a moved row keeps the one it was configured with.
    private func updateSeparators() {
        let rowCount = tableView.numberOfRows
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView as? OrganizerItemRowView)?.showsSeparator = row < rowCount - 1
        }
    }

    /// Sends the order the list was dragged into to the Dock. The list shows it already; when the Dock
    /// refuses it, the layout stays as it was and no refresh brings the list back — the Dock reports the
    /// layout unchanged — so the list shows the layout again once the edit is over.
    private func commitReorder(to order: [LaunchpadOrganizer.ItemIdentifier]) {
        updateSeparators()
        Task { [weak self] in
            guard let self else { return }
            if let operation = viewModel.reorderOperation(to: order) {
                await viewModel.perform(operation)
            }
            show(viewModel.rows, selecting: viewModel.selectedItems)
        }
    }

    /// What covers the list when it has nothing to show: the Dock not answering yet, no layout to organize
    /// and why, a search without matches, or an empty page or folder.
    private func contentUnavailableConfiguration() -> NSContentUnavailableConfiguration? {
        let organizer = viewModel.organizer
        switch organizer.availability {
        case .loading where organizer.layout == nil:
            var configuration = NSContentUnavailableConfiguration.loading()
            configuration.text = "Reading the layout from the Dock…"
            return configuration
        case .unavailable(let reason):
            var configuration = NSContentUnavailableConfiguration.empty()
            configuration.image = NSImage(systemSymbolName: "square.grid.3x3.slash", accessibilityDescription: nil)
            configuration.text = "Nothing to Organize"
            configuration.secondaryText = reason
            if injectionCoordinator.residentPayloads.first?.isStale == true {
                configuration.button = .push()
                configuration.button.title = "Restart Dock"
                configuration.buttonProperties.isEnabled = !injectionCoordinator.isBusy
                configuration.buttonProperties.primaryAction = NSAction { [injectionCoordinator] _ in
                    injectionCoordinator.restartTargets()
                }
            }
            return configuration
        default:
            guard organizer.layout != nil, viewModel.rows.isEmpty else { return nil }
            var configuration = viewModel.isSearching ? NSContentUnavailableConfiguration.search() : NSContentUnavailableConfiguration.empty()
            configuration.image = NSImage(systemSymbolName: viewModel.isSearching ? "magnifyingglass" : "tray", accessibilityDescription: nil)
            configuration.text = viewModel.isSearching ? "No Matches" : "Empty"
            return configuration
        }
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isMatchingSelection else { return }
        let selectedItems = Set(tableView.selectedRowIndexes.compactMap { dataSource.itemIdentifier(forRow: $0)?.id })
        if selectedItems != viewModel.selectedItems {
            viewModel.selectedItems = selectedItems
        }
    }

    // MARK: - Opening

    @objc private func openClickedRow(_ sender: Any?) {
        guard tableView.clickedRow >= 0, let row = dataSource.itemIdentifier(forRow: tableView.clickedRow) else { return }
        viewModel.open([row.id])
    }

    // MARK: - Context menu

    /// The right-click menu, for the rows it was opened on: the selection when the clicked row is part of
    /// it, else that row.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        guard tableView.clickedRow >= 0, let clickedRow = dataSource.itemIdentifier(forRow: tableView.clickedRow), let layout = viewModel.layout else { return }
        let targets = viewModel.targetItems(forRow: clickedRow.id)
        for item in OrganizerMenus.itemMenuItems(for: targets, in: layout, viewModel: viewModel) {
            menu.addItem(item)
        }
    }
}

/// The list's table: Return opens the selection, as a double-click opens the clicked row.
final class OrganizerTableView: NSTableView, @unchecked Sendable {
    var openSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if let characters = event.charactersIgnoringModifiers, characters == "\r" || characters == "\u{3}", !selectedRowIndexes.isEmpty {
            openSelection?()
            return
        }
        super.keyDown(with: event)
    }

    /// Keeps AppKit's own tracking loop for clicks. On macOS 27 a table tracks clicks with gesture
    /// recognizers, and a click no longer makes it the first responder, so selected rows stay grey; with
    /// `mouseDown(with:)` overridden AppKit installs no recognizers and keeps the earlier behaviour.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}

/// The list's rows and their drags. AppKitPlus's reorder data source moves rows within the page or folder
/// shown; this subclass adds what a reorder is not: a drop onto a folder's row puts the items into the
/// folder, and every dragged row carries its identifier for the sidebar and the folder rows to read.
@MainActor
private final class OrganizerItemsDataSource: NSTableViewDiffableReorderableDataSource<Int, LaunchpadOrganizerViewModel.Row> {
    weak var viewModel: LaunchpadOrganizerViewModel?

    /// The reorder data source writes a row only while the list can be reordered; search results are
    /// still dragged, onto the sidebar.
    override func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let item = itemIdentifier(forRow: row) else { return nil }
        let reorderItem = super.tableView(tableView, pasteboardWriterForRow: row) as? NSPasteboardItem
        return OrganizerPasteboard.pasteboardItem(for: item.id, addingTo: reorderItem)
    }

    /// Decided before the reorder targeting, which turns every drop onto a row into a drop above it.
    override func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if folderDropOperation(info, row: row, dropOperation: dropOperation) != nil {
            return .move
        }
        return super.tableView(tableView, validateDrop: info, proposedRow: row, proposedDropOperation: dropOperation)
    }

    override func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let viewModel, let operation = folderDropOperation(info, row: row, dropOperation: dropOperation) else {
            return super.tableView(tableView, acceptDrop: info, row: row, dropOperation: dropOperation)
        }
        Task {
            await viewModel.perform(operation)
        }
        return true
    }

    /// Moving the dragged items into the folder whose row the drop is on; nil for any other drop.
    private func folderDropOperation(_ info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> LaunchpadOrganizerViewModel.DropOperation? {
        guard dropOperation == .on, let item = itemIdentifier(forRow: row), case .folder = item.item else { return nil }
        return viewModel?.dropOperation(of: OrganizerPasteboard.draggedItems(in: info), onto: .row(item.id))
    }
}

/// An application or a folder in the list. Its content comes from a list content configuration.
final class OrganizerItemCellView: NSTableCellView {
    static let iconSize: CGFloat = 28

    /// The row height SwiftUI's list gave a 28-point icon; a folder's smaller symbol keeps it too.
    private static let minimumHeight: CGFloat = 38

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A row of the list, with a hairline under it that starts where the text does, as the SwiftUI list drew.
final class OrganizerItemRowView: NSTableRowView {
    /// Where the separator starts: the cell's leading margin, the icon, and the space after it.
    private static let separatorLeadingInset: CGFloat = 50

    var showsSeparator = false {
        didSet {
            separatorView.isHidden = !showsSeparator
        }
    }

    private let separatorView = XiblessView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separatorView.backgroundColor = .separatorColor
        separatorView.isHidden = true
        addSubview(separatorView)
        separatorView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Self.separatorLeadingInset)
            make.trailing.equalToSuperview().offset(-8)
            make.bottom.equalToSuperview()
            make.height.equalTo(1)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The bar under the list: an edit on its way to the Dock, or the last one that failed.
final class OrganizerStatusBarView: XiblessView {
    private let effectView = NSVisualEffectView()
    private let progressIndicator = NSProgressIndicator()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var heightWhenHidden: Constraint?

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        effectView.material = .titlebar
        effectView.blendingMode = .withinWindow
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        messageLabel.font = .preferredFont(forTextStyle: .callout)
        messageLabel.maximumNumberOfLines = 2
        messageLabel.isSelectable = false
        let topBorder = NSBox()
        topBorder.boxType = .separator

        let stackView = NSStackView(views: [progressIndicator, messageLabel])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.detachesHiddenViews = true

        hierarchy {
            effectView
            topBorder
            stackView
        }
        effectView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        topBorder.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }
        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)).priority(.high)
        }
        snp.makeConstraints { make in
            heightWhenHidden = make.height.equalTo(0).constraint
        }
    }

    func show(isApplying: Bool, errorDescription: String?) {
        if isApplying {
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            messageLabel.attributedStringValue = NSAttributedString(string: "Updating Launchpad…", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        } else if let errorDescription {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            messageLabel.attributedStringValue = Self.warningText(errorDescription)
        }
        let isShown = isApplying || errorDescription != nil
        isHidden = !isShown
        if isShown {
            heightWhenHidden?.deactivate()
        } else {
            heightWhenHidden?.activate()
        }
    }

    private static func warningText(_ description: String) -> NSAttributedString {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let symbol = NSTextAttachment()
        symbol.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular))
        let text = NSMutableAttributedString(attachment: symbol)
        text.append(NSAttributedString(string: " " + description))
        text.addAttributes([.foregroundColor: NSColor.systemOrange, .font: font], range: NSRange(location: 0, length: text.length))
        return text
    }

    override func layout() {
        super.layout()
        let messageWidth = messageLabel.frame.width
        if messageWidth > 0, messageLabel.preferredMaxLayoutWidth != messageWidth {
            messageLabel.preferredMaxLayoutWidth = messageWidth
            needsLayout = true
        }
    }
}
