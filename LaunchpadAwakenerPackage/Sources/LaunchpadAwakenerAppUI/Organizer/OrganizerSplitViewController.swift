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
    private var isPresentingConfirmations = false

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
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The confirmation is a sheet on the window, which only exists once the view is in one.
        if !isPresentingConfirmations, let window = view.window {
            isPresentingConfirmations = true
            window.sheet(item: $viewModel.folderBeingDissolved) { [viewModel] folder in
                FolderDissolveConfirmation.alert(for: folder) {
                    Task { await viewModel.dissolve(folder) }
                }
            }
        }
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
