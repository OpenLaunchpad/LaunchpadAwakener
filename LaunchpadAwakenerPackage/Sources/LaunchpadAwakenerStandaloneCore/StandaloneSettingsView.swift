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

    /// Brings the settings up, as the app menu's Settings… does. The springboard hides first: it covers the
    /// whole screen.
    @MainActor
    public static func show() {
        StandaloneLaunchpad.shared.hide(reason: "showing the settings")
        NSApp.activate()
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
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
