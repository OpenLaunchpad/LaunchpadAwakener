@testable import LaunchpadAwakenerStandaloneCore
import Testing

/// Whether the standalone app covers the screen as it launches: only when the user opened it.
@Suite("Showing the standalone springboard at launch")
struct StandaloneLaunchShowingTests {
    @Test("opened by the user, it shows")
    func standaloneShowsWhenOpenedByTheUser() {
        #expect(StandaloneLaunchShowing.showsOnLaunch(wasLaunchedAtLogin: false, wasRelaunchedForUpdate: false))
    }

    @Test("opened at login, it waits for the Dock icon")
    func standaloneStaysHiddenWhenLaunchedAtLogin() {
        #expect(!StandaloneLaunchShowing.showsOnLaunch(wasLaunchedAtLogin: true, wasRelaunchedForUpdate: false))
    }

    @Test("reopened by Sparkle to finish an update, it waits for the Dock icon")
    func standaloneStaysHiddenWhenRelaunchedForAnUpdate() {
        #expect(!StandaloneLaunchShowing.showsOnLaunch(wasLaunchedAtLogin: false, wasRelaunchedForUpdate: true))
    }
}
