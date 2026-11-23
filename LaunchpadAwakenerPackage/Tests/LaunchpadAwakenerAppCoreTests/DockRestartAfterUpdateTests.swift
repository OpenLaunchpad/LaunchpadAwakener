@testable import LaunchpadAwakenerAppCore
import Testing

/// The one Dock restart an update brings: the Dock keeps running the old payload, which only a restart
/// replaces, so the first launch of the new build restarts it.
@Suite("Restarting the Dock after an update")
struct DockRestartAfterUpdateTests {
    @Test("the first launch of a new build restarts a Dock that runs an older payload")
    func restartsTheDockOnceForANewBuildWithAStalePayload() {
        #expect(DockRestartAfterUpdate.isNeeded(isNewBuild: true, isInjectionAllowed: true, hasStalePayload: true))
    }

    @Test("a Dock running this build's payload, or none, is left alone")
    func doesNotRestartWithoutAStalePayload() {
        #expect(!DockRestartAfterUpdate.isNeeded(isNewBuild: true, isInjectionAllowed: true, hasStalePayload: false))
    }

    @Test("nothing restarts while SIP keeps the app from injecting")
    func doesNotRestartWhileInjectionIsBlocked() {
        #expect(!DockRestartAfterUpdate.isNeeded(isNewBuild: true, isInjectionAllowed: false, hasStalePayload: true))
    }

    @Test("a later launch of the same build leaves an older payload to the control panel's Restart Dock")
    func doesNotRestartForTheSameBuild() {
        #expect(!DockRestartAfterUpdate.isNeeded(isNewBuild: false, isInjectionAllowed: true, hasStalePayload: true))
    }
}
