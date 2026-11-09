import AppKit
import Testing
@testable import LaunchpadAwakenerSharedUI

/// The main menu both apps build in code, against what SwiftUI generated for them on macOS 27.2: no
/// File menu, Close at the top of the Window menu, the app's windows listed there, and Settings… only
/// for an app that has settings.
@Suite("Application main menu")
@MainActor
struct ApplicationMainMenuTests {
    private static func submenuTitles(_ menu: NSMenu, _ title: String) throws -> [String] {
        let submenu = try #require(menu.items.first { $0.title == title }?.submenu, "no \(title) menu")
        return submenu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    @Test("the menu bar has the application menu, Edit, View, Window and Help, and no File menu")
    func topLevelMenus() {
        let menu = ApplicationMainMenu.make(applicationName: "LaunchpadAwakener")
        #expect(menu.items.map(\.title) == ["LaunchpadAwakener", "Edit", "View", "Window", "Help"])
    }

    @Test("the application menu has no Settings… unless the app has settings")
    func applicationMenuWithoutSettings() throws {
        let menu = ApplicationMainMenu.make(applicationName: "LaunchpadAwakener")
        #expect(try Self.submenuTitles(menu, "LaunchpadAwakener") == [
            "About LaunchpadAwakener", "-", "Services", "-", "Hide LaunchpadAwakener", "Hide Others", "Show All", "-", "Quit LaunchpadAwakener",
        ])
    }

    @Test("an app with settings gets them right after About")
    func applicationMenuWithSettings() throws {
        let settingsItem = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
        let menu = ApplicationMainMenu.make(applicationName: "Launchpad", settingsItem: settingsItem)
        #expect(try Self.submenuTitles(menu, "Launchpad").prefix(5) == ["About Launchpad", "-", "Settings…", "-", "Services"])
    }

    @Test("the Window menu starts with Close on Command-W and lists the app's windows")
    func windowMenu() throws {
        let windowItems = [NSMenuItem(title: "LaunchpadAwakener", action: nil, keyEquivalent: ""), NSMenuItem(title: "Organize Launchpad", action: nil, keyEquivalent: "")]
        let menu = ApplicationMainMenu.make(applicationName: "LaunchpadAwakener", windowItems: windowItems)
        #expect(try Self.submenuTitles(menu, "Window") == ["Close", "Minimize", "Zoom", "-", "LaunchpadAwakener", "Organize Launchpad", "-", "Bring All to Front"])
        let closeItem = try #require(menu.items.first { $0.title == "Window" }?.submenu?.items.first)
        #expect(closeItem.keyEquivalent == "w")
        #expect(closeItem.keyEquivalentModifierMask == .command)
    }

    @Test("the windows the Window menu lists are wired as the app's window menu")
    func windowsMenuIsWired() {
        let menu = ApplicationMainMenu.make(applicationName: "LaunchpadAwakener")
        NSApplication.shared.mainMenu = menu
        #expect(NSApplication.shared.windowsMenu === menu.items.first { $0.title == "Window" }?.submenu)
    }

    @Test("windows do not tab: the tab commands stay out of the View and Window menus")
    func windowTabbingIsOff() {
        _ = ApplicationMainMenu.make(applicationName: "LaunchpadAwakener")
        #expect(!NSWindow.allowsAutomaticWindowTabbing)
    }
}
