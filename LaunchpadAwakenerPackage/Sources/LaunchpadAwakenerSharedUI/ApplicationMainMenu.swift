import AppKit
import UIFoundation

/// The main menu both apps had under SwiftUI, built in code from UIFoundation's standard items: the
/// application menu, Edit, View, Window and Help.
///
/// There is no File menu: Close sits in the Window menu, which also lists the app's own windows as
/// commands that open them, whether or not they are open — those windows keep themselves out of the
/// automatic window list. The View menu shows its toolbar and sidebar items only while the key window
/// has a toolbar or a sidebar, as SwiftUI's did.
@MainActor
public enum ApplicationMainMenu {
    /// - Parameters:
    ///   - settingsItem: The application menu's Settings… item, for an app that has settings.
    ///   - windowItems: Commands that open the app's windows, listed in the Window menu.
    public static func make(applicationName: String, settingsItem: NSMenuItem? = nil, windowItems: [NSMenuItem] = []) -> NSMenu {
        // SwiftUI's windows did not tab; without this AppKit adds Show Tab Bar and the tab commands to the
        // View and Window menus.
        NSWindow.allowsAutomaticWindowTabbing = false

        let viewMenuItem = MainMenu.view {
            MainMenu.View.showToolbar()
            MainMenu.View.customizeToolbar()
            MainMenu.View.showSidebar()
            NSMenuItem.separator()
            MainMenu.View.enterFullScreen()
        }
        viewMenuItem.submenu?.delegate = ViewMenuVisibility.shared

        return MainMenu.menu {
            MainMenu.application(applicationName: applicationName) {
                MainMenu.Application.about(applicationName: applicationName)
                NSMenuItem.separator()
                if let settingsItem {
                    settingsItem
                    NSMenuItem.separator()
                }
                MainMenu.Application.services()
                NSMenuItem.separator()
                MainMenu.Application.hide(applicationName: applicationName)
                MainMenu.Application.hideOthers()
                MainMenu.Application.showAll()
                NSMenuItem.separator()
                MainMenu.Application.quit(applicationName: applicationName)
            }
            MainMenu.edit {
                MainMenu.Edit.undo()
                MainMenu.Edit.redo()
                NSMenuItem.separator()
                MainMenu.Edit.cut()
                MainMenu.Edit.copy()
                MainMenu.Edit.paste()
                MainMenu.Edit.delete()
                MainMenu.Edit.selectAll()
            }
            viewMenuItem
            MainMenu.window {
                NSMenuItem("Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
                MainMenu.Window.minimize()
                MainMenu.Window.zoom()
                if !windowItems.isEmpty {
                    NSMenuItem.separator()
                    windowItems
                }
                NSMenuItem.separator()
                MainMenu.Window.bringAllToFront()
            }
            MainMenu.help(applicationName: applicationName)
        }
    }
}

/// Hides the View menu's toolbar items while the key window has no toolbar, and its sidebar item while
/// the key window has no sidebar, each time the menu opens.
@MainActor
private final class ViewMenuVisibility: NSObject, NSMenuDelegate {
    static let shared = ViewMenuVisibility()

    func menuNeedsUpdate(_ menu: NSMenu) {
        let keyWindow = NSApp.keyWindow
        let hasToolbar = keyWindow?.toolbar != nil
        let canCustomizeToolbar = keyWindow?.toolbar?.allowsUserCustomization ?? false
        let splitViewController = keyWindow?.contentViewController as? NSSplitViewController
        let hasSidebar = splitViewController?.splitViewItems.contains { $0.behavior == .sidebar } ?? false
        for item in menu.items {
            switch item.action {
            case #selector(NSWindow.toggleToolbarShown(_:)):
                item.isHidden = !hasToolbar
            case #selector(NSWindow.runToolbarCustomizationPalette(_:)):
                item.isHidden = !canCustomizeToolbar
            case #selector(NSSplitViewController.toggleSidebar(_:)):
                item.isHidden = !hasSidebar
            default:
                break
            }
        }
        // The separator only stands between the toolbar or sidebar items and Enter Full Screen.
        menu.items.first(where: \.isSeparatorItem)?.isHidden = !hasToolbar && !hasSidebar
    }
}
