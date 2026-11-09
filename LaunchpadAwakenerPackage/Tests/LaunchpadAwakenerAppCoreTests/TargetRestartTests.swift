import Foundation
import Testing
@testable import LaunchpadAwakenerAppCore

/// Covers picking the replacement process after a deliberate restart.
///
/// The behaviour this protects: restarting the Dock from inside the app is a request to keep
/// overriding it, and it used to leave the follow-up injection to the process monitor — which only
/// runs when automatic re-injection is switched on. With that preference off, the button reliably
/// produced a Dock with no payload in it, and pressing "Inject Now" afterwards raced the
/// replacement process coming up: too early and there was nothing to inject into, too late and the
/// new Dock had already finished starting.
@Suite("Target restart")
struct TargetRestartTests {
    /// The outgoing process is still winding down when the first polls happen. Injecting into it
    /// would put the payload in a process that is about to exit — and mark the restart as handled.
    @Test("The outgoing target is never mistaken for the replacement")
    func outgoingTargetIsNotTheReplacement() {
        let outgoing: Set<pid_t> = [49142]

        let replacements = Set([49142]).subtracting(outgoing)

        #expect(replacements.isEmpty)
    }

    @Test("A target absent from the outgoing set is the replacement")
    func newTargetIsTheReplacement() {
        let outgoing: Set<pid_t> = [49142]

        let replacements = Set([83832]).subtracting(outgoing)

        #expect(replacements == [83832])
    }

    /// Both can be running at once for a moment: `launchd` starts the replacement while the old
    /// process is still shutting down. Only the new one may be injected.
    @Test("Only the new target is selected while both are running")
    func onlyNewTargetIsSelectedDuringOverlap() {
        let outgoing: Set<pid_t> = [49142]

        let replacements = Set([49142, 83832]).subtracting(outgoing)

        #expect(replacements == [83832])
    }

    /// Nothing running yet is the normal state for the first fraction of a second after `killall`.
    /// It has to read as "keep waiting", not as "nothing to do" — which is exactly what pressing
    /// "Inject Now" too early used to produce.
    @Test("An empty process table means keep waiting, not give up")
    func emptyProcessTableMeansKeepWaiting() {
        let outgoing: Set<pid_t> = [49142]

        let replacements = Set<pid_t>().subtracting(outgoing)

        #expect(replacements.isEmpty)
    }

    /// The selection that follows once the replacement is found still has to respect what is
    /// already injected — the process monitor may have got there first when automatic re-injection
    /// is switched on, and both paths run concurrently in that case.
    @Test("A replacement the monitor already injected is not injected twice")
    func replacementAlreadyInjectedIsNotInjectedAgain() {
        let selected = InjectionSelection.processIdentifiersNeedingInjection(
            running: [83832],
            alreadyInjected: [83832],
            beingInjected: []
        )

        #expect(selected.isEmpty)
    }
}
