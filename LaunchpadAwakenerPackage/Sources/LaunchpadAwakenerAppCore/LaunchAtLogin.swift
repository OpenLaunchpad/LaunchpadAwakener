import Foundation
import OSLog
import ServiceManagement

/// Keeps the app among the user's login items while automatic injection is on, so the Dock is injected
/// again after every login, not only after the app is opened by hand.
@MainActor
public enum LaunchAtLogin {
    private static let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakener", category: "LaunchAtLogin")

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ shouldBeEnabled: Bool) {
        guard shouldBeEnabled != isEnabled else { return }
        do {
            if shouldBeEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            logger.info("Launch at login \(shouldBeEnabled ? "enabled" : "disabled", privacy: .public)")
        } catch {
            logger.error("Could not change launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }
}
