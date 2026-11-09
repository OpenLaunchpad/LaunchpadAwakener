import AppKit
import AppKitPlus
import LaunchpadAwakenerAppCore

/// The organizer's menus, shared by the toolbar and the list's context menu: Move To, the actions on
/// selected items, and Arrange. Each is built when it opens, from the layout and selection of the moment.
@MainActor
enum OrganizerMenus {
    typealias ItemIdentifier = LaunchpadOrganizer.ItemIdentifier

    /// Every page, a new page, then every folder — which only applications can go into.
    static func moveMenuItems(for itemIdentifiers: Set<ItemIdentifier>, in layout: LaunchpadOrganizer.Layout, viewModel: LaunchpadOrganizerViewModel) -> [NSMenuItem] {
        var menuItems = layout.pages.map { page in
            item("Page \(page.number)") {
                await viewModel.move(itemIdentifiers, to: .page(page.id))
            }
        }
        menuItems.append(item("New Page") {
            await viewModel.move(itemIdentifiers, to: .newPage)
        })
        let folders = layout.folders
        if !folders.isEmpty {
            menuItems.append(.separator())
            let canMoveIntoFolder = viewModel.canMoveIntoFolder(itemIdentifiers)
            for folder in folders {
                let menuItem = item(folder.title) {
                    await viewModel.move(itemIdentifiers, to: .folder(folder.id))
                }
                menuItem.isEnabled = canMoveIntoFolder
                menuItems.append(menuItem)
            }
        }
        return menuItems
    }

    /// The context menu of the rows `targets` stands for.
    static func itemMenuItems(for targets: Set<ItemIdentifier>, in layout: LaunchpadOrganizer.Layout, viewModel: LaunchpadOrganizerViewModel) -> [NSMenuItem] {
        guard !targets.isEmpty else { return [] }
        let moveToMenu = NSMenu(title: "Move To")
        moveToMenu.autoenablesItems = false
        moveToMenu.items = moveMenuItems(for: targets, in: layout, viewModel: viewModel)
        let moveToItem = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
        moveToItem.submenu = moveToMenu

        let newFolderItem = actionItem("New Folder with Selection…") {
            viewModel.beginNewFolder(from: targets)
        }
        newFolderItem.isEnabled = viewModel.canMakeFolder(from: targets)

        var menuItems = [moveToItem, newFolderItem]
        if viewModel.isAnyInFolder(targets) {
            menuItems.append(item("Move Out of Folder") {
                await viewModel.moveOutOfFolders(targets)
            })
        }
        if targets.count == 1, let onlyTarget = targets.first, let folder = layout.folder(onlyTarget) {
            menuItems += [
                .separator(),
                actionItem("Open Folder") {
                    viewModel.show(.folder(folder.id))
                },
                actionItem("Rename Folder…") {
                    viewModel.beginRenaming(folder)
                },
                actionItem("Dissolve Folder…") {
                    viewModel.beginDissolving(folder)
                },
            ]
        }
        return menuItems
    }

    /// Sort the page or folder shown, rename or dissolve the folder shown, or group by category.
    static func arrangeMenuItems(viewModel: LaunchpadOrganizerViewModel) -> [NSMenuItem] {
        var menuItems: [NSMenuItem] = []
        if let selectedContainer = viewModel.selectedContainer, !viewModel.isSearching {
            menuItems.append(item("Sort by Name") {
                await viewModel.sortByName(selectedContainer)
            })
        }
        if case .folder(let folderIdentifier) = viewModel.selectedContainer, let folder = viewModel.layout?.folder(folderIdentifier) {
            if !menuItems.isEmpty {
                menuItems.append(.separator())
            }
            menuItems += [
                actionItem("Rename Folder…") {
                    viewModel.beginRenaming(folder)
                },
                actionItem("Dissolve Folder…") {
                    viewModel.beginDissolving(folder)
                },
            ]
        }
        if !menuItems.isEmpty {
            menuItems.append(.separator())
        }
        menuItems.append(actionItem("Group by Category…") {
            viewModel.beginGroupingByCategory()
        })
        return menuItems
    }

    /// An item whose action is an edit sent to the Dock.
    private static func item(_ title: String, perform edit: @escaping @MainActor () async -> Void) -> NSMenuItem {
        actionItem(title) {
            Task { await edit() }
        }
    }

    private static func actionItem(_ title: String, perform action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.primaryAction = NSAction { _ in
            action()
        }
        return menuItem
    }
}

/// Rebuilds a menu from the organizer's state each time it opens.
@MainActor
final class OrganizerMenuUpdater: NSObject, NSMenuDelegate {
    private let makeItems: () -> [NSMenuItem]

    init(makeItems: @escaping () -> [NSMenuItem]) {
        self.makeItems = makeItems
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.items = makeItems()
    }
}
