import AppKit
import KeyboardShortcuts
import OSToolbox
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Shows the springboard, or hides it. Not set until the user records one, as macOS 15's "Show
    /// Launchpad" shortcut was not.
    static let toggleLaunchpad = Self("toggleLaunchpad")
}

/// The standalone app's settings: the shortcut that shows Launchpad, and whether it opens at login.
public struct StandaloneSettingsView: View {
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    public init() {}

    public var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Show Launchpad:", name: .toggleLaunchpad)
            Toggle("Open at Login", isOn: $opensAtLogin)
                .onChange(of: opensAtLogin) { _, newValue in
                    StandaloneLoginItem.setOpensAtLogin(newValue)
                    opensAtLogin = SMAppService.mainApp.status == .enabled
                }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }
}

/// Opening the settings from outside SwiftUI: the Dock icon's menu.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "StandaloneSettings")
@MainActor
enum StandaloneSettings {
    /// Brings the settings up, as the app menu's Settings… does. The springboard hides first: it covers the
    /// whole screen.
    ///
    /// Since macOS 14 SwiftUI opens its Settings scene only through its own menu item — the
    /// `showSettingsWindow:` action sent along the responder chain is ignored — so this performs that item.
    static func show() {
        StandaloneLaunchpad.shared.hide(reason: "showing the settings", returningToPreviousApplication: false)
        NSApp.activate()
        guard
            let applicationMenu = NSApp.mainMenu?.items.first?.submenu,
            let settingsItemIndex = applicationMenu.items.firstIndex(where: { menuItem in
                menuItem.keyEquivalent == "," && menuItem.keyEquivalentModifierMask == .command
            })
        else {
            #log(.error, "The app menu has no Settings… item to open the settings with")
            return
        }
        applicationMenu.performActionForItem(at: settingsItemIndex)
    }
}

/// Opening at login, through `SMAppService.mainApp`: the app appears under Open at Login in System
/// Settings, where the user can also take it out.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "StandaloneLoginItem")
@MainActor
enum StandaloneLoginItem {
    static func setOpensAtLogin(_ opensAtLogin: Bool) {
        do {
            if opensAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            #log(.info, "Opens at login: \(opensAtLogin, privacy: .public)")
        } catch {
            #log(.error, "Could not change opening at login to \(opensAtLogin, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
