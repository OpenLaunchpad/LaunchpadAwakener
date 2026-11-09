import AppKit
import AppKitNavigation
import LaunchpadAwakenerAppCore
import UIFoundation

/// The organizer window's content: the sidebar of pages and folders, the list beside it, and the sheets
/// and confirmation the view model asks for.
///
/// While the window is on screen it asks the Dock every few seconds whether the layout changed, and stops
/// when the window closes.
final class OrganizerSplitViewController: XiblessSplitViewController {
    /// How often the window asks the Dock whether the layout changed while it is open.
    private static let refreshInterval = Duration.seconds(3)

    @UIBindable private var viewModel: LaunchpadOrganizerViewModel
    private let injectionCoordinator: PayloadInjectionCoordinator
    private var refreshTask: Task<Void, Never>?
    private var isConfirmingDissolve = false

    init(viewModel: LaunchpadOrganizerViewModel, injectionCoordinator: PayloadInjectionCoordinator) {
        self.viewModel = viewModel
        self.injectionCoordinator = injectionCoordinator
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: OrganizerSidebarViewController(viewModel: viewModel))
        sidebarItem.minimumThickness = 200
        sidebarItem.preferredThicknessFraction = 0.25
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: OrganizerItemsViewController(viewModel: viewModel, injectionCoordinator: injectionCoordinator))
        contentItem.minimumThickness = 400
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        present(item: $viewModel.folderNaming, style: .sheet) { [viewModel] naming in
            FolderNameViewController(naming: naming) { name in
                Task { await viewModel.finishNaming(naming, name: name) }
            }
        }
        present(item: $viewModel.categoryGrouping, style: .sheet) { [viewModel] grouping in
            CategoryGroupingViewController(grouping: grouping) {
                Task { await viewModel.groupByCategory(grouping) }
            }
        }
        // The confirmation is an alert sheet begun by hand. swift-navigation 2.11.101 begins an alert's window
        // as a plain sheet, past `beginSheetModal(for:)`, so the alert is never laid out and shows its
        // nib's placeholders — an empty button, a help button, an unlabelled suppression checkbox.
        observe { [weak self] in
            guard let self, let folder = viewModel.folderBeingDissolved else { return }
            confirmDissolving(folder)
        }
    }

    private func confirmDissolving(_ folder: LaunchpadOrganizer.Folder) {
        guard !isConfirmingDissolve, let window = view.window else { return }
        isConfirmingDissolve = true
        FolderDissolveConfirmation.alert(for: folder).beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            isConfirmingDissolve = false
            viewModel.folderBeingDissolved = nil
            if response == .alertFirstButtonReturn {
                Task { [viewModel] in await viewModel.dissolve(folder) }
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await injectionCoordinator.refreshState()
                await viewModel.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        refreshTask?.cancel()
        refreshTask = nil
    }
}
