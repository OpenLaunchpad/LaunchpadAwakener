import LaunchpadAwakenerStandaloneCore
import SwiftUI

/// The standalone Launchpad: macOS 15's Launchpad in a window of its own, over the whole main display,
/// without injecting into the Dock. Everything but this shell is in `LaunchpadAwakenerStandaloneCore`.
@main
struct LaunchpadApp: App {
    @NSApplicationDelegateAdaptor(StandaloneApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        Settings {
            StandaloneSettingsView()
        }
    }
}
