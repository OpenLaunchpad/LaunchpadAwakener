import OSToolbox
import ServiceManagement
import SwiftUI

/// The standalone app's settings: whether it opens at login.
public struct StandaloneSettingsView: View {
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    public init() {}

    public var body: some View {
        Form {
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
