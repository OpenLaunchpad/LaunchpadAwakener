import AppKit
import AppKitNavigation
import AppKitPlus
import LaunchpadAwakenerAppCore
import UIFoundation
import UIFoundationToolbox

/// The window for organizing the Launchpad layout: pages and folders on the left, what the selected one
/// holds on the right, and a toolbar acting on every selected item at once.
final class OrganizerWindowController: ActivationTrackingWindowController {
    private static let defaultContentSize = NSSize(width: 900, height: 620)
    private static let minimumContentSize = NSSize(width: 760, height: 480)

    @UIBindable private var viewModel: LaunchpadOrganizerViewModel
    private let injectionCoordinator: PayloadInjectionCoordinator

    private let searchField = NSSearchField()
    private lazy var moveToMenuUpdater = OrganizerMenuUpdater { [weak self] in
        guard let self, let layout = viewModel.layout else { return [] }
        return OrganizerMenus.moveMenuItems(for: viewModel.selectedItems, in: layout, viewModel: viewModel)
    }
    private lazy var arrangeMenuUpdater = OrganizerMenuUpdater { [weak self] in
        guard let self else { return [] }
        return OrganizerMenus.arrangeMenuItems(viewModel: viewModel)
    }
    private var backItem: NSToolbar.Button?
    private var moveToItem: NSToolbar.Menu?
    private var newFolderItem: NSToolbar.Button?
    private var moveOutItem: NSToolbar.Button?
    private var arrangeItem: NSToolbar.Menu?

    init(viewModel: LaunchpadOrganizerViewModel, injectionCoordinator: PayloadInjectionCoordinator, activationPolicyController: ApplicationActivationPolicyController) {
        self.viewModel = viewModel
        self.injectionCoordinator = injectionCoordinator
        super.init(
            window: NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: true
            ),
            activationPolicyController: activationPolicyController
        )
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        contentWindow.contentViewController = OrganizerSplitViewController(viewModel: viewModel, injectionCoordinator: injectionCoordinator)
        contentWindow.contentMinSize = Self.minimumContentSize
        contentWindow.toolbarStyle = .unified
        contentWindow.toolbar = makeToolbar()
        contentWindow.isExcludedFromWindowsMenu = true
        contentWindow.setContentSize(Self.defaultContentSize)
        contentWindow.center()
        // The same name SwiftUI kept this window's frame under, so the frame carries over.
        contentWindow.setFrameAutosaveName("organizer")

        observe { [weak self] in
            guard let self else { return }
            contentWindow.title = viewModel.title
            contentWindow.subtitle = viewModel.subtitle
        }
        observe { [weak self] in
            guard let self else { return }
            let selectedItems = viewModel.selectedItems
            let isApplying = viewModel.organizer.isApplying
            backItem?.isEnabled = viewModel.canGoBack
            moveToItem?.isEnabled = viewModel.layout != nil && !selectedItems.isEmpty && !isApplying
            newFolderItem?.isEnabled = viewModel.canMakeFolder(from: selectedItems)
            moveOutItem?.isEnabled = viewModel.isAnyInFolder(selectedItems) && !isApplying
            arrangeItem?.isEnabled = viewModel.layout != nil && !isApplying
        }
        searchField.bind(text: $viewModel.searchText)
    }

    private func makeToolbar() -> NSToolbar {
        let backItem = NSToolbar.Button(.organizerBack, image: Self.symbol("chevron.left", "Back")) { [weak self] _ in
            self?.viewModel.goBack()
        }
        .label("Back")
        .toolTip("Back to the page or folder shown before")
        .shortcut("[", holding: .command)
        .isNavigational(true)
        .autovalidates(false)

        let moveToMenu = NSMenu(title: "Move To")
        moveToMenu.delegate = moveToMenuUpdater
        let moveToItem = NSToolbar.Menu(.organizerMoveTo, image: Self.symbol("arrow.right.square", "Move To"), menu: moveToMenu)
            .label("Move To")
            .toolTip("Move the selected items to another page or into a folder")
            .autovalidates(false)

        let newFolderItem = NSToolbar.Button(.organizerNewFolder, image: Self.symbol("folder.badge.plus", "New Folder")) { [weak self] _ in
            guard let self else { return }
            viewModel.beginNewFolder(from: viewModel.selectedItems)
        }
        .label("New Folder")
        .toolTip("Put the selected applications into a new folder")
        .autovalidates(false)

        let moveOutItem = NSToolbar.Button(.organizerMoveOut, image: Self.symbol("arrow.up.right.square", "Move Out of Folder")) { [weak self] _ in
            guard let viewModel = self?.viewModel else { return }
            let selectedItems = viewModel.selectedItems
            Task { await viewModel.moveOutOfFolders(selectedItems) }
        }
        .label("Move Out of Folder")
        .toolTip("Move the selected applications out of their folders, to the end of the folder's page")
        .autovalidates(false)

        let arrangeMenu = NSMenu(title: "Arrange")
        arrangeMenu.delegate = arrangeMenuUpdater
        let arrangeItem = NSToolbar.Menu(.organizerArrange, image: Self.symbol("arrow.up.arrow.down", "Arrange"), menu: arrangeMenu)
            .label("Arrange")
            .toolTip("Sort, rename or dissolve the selected folder, or group applications by category")
            .autovalidates(false)

        searchField.placeholderString = "Search Applications"
        let searchItem = NSToolbar.Search(.organizerSearch, searchField: searchField)
            .label("Search")

        self.backItem = backItem
        self.moveToItem = moveToItem
        self.newFolderItem = newFolderItem
        self.moveOutItem = moveOutItem
        self.arrangeItem = arrangeItem

        // New Folder and Move Out of Folder share one capsule, as SwiftUI's toolbar group drew them.
        let folderItems = NSToolbar.Group(.organizerFolderActions, items: [newFolderItem, moveOutItem])

        let toolbar = NSToolbar("OrganizerToolbar", allowsUserCustomization: false) {
            // The sidebar button sits at the sidebar's trailing edge, beside the split.
            NSToolbar.box.flexibleSpace
            NSToolbar.box.toggleSidebar
            NSToolbar.box.sidebarTrackingSeparator
            backItem
            NSToolbar.box.flexibleSpace
            moveToItem
            folderItems
            arrangeItem
            searchItem
        }
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }
}

extension NSToolbarItem.Identifier {
    static let organizerBack = NSToolbarItem.Identifier("organizer.back")
    static let organizerMoveTo = NSToolbarItem.Identifier("organizer.moveTo")
    static let organizerNewFolder = NSToolbarItem.Identifier("organizer.newFolder")
    static let organizerMoveOut = NSToolbarItem.Identifier("organizer.moveOut")
    static let organizerFolderActions = NSToolbarItem.Identifier("organizer.folderActions")
    static let organizerArrange = NSToolbarItem.Identifier("organizer.arrange")
    static let organizerSearch = NSToolbarItem.Identifier("organizer.search")
}
