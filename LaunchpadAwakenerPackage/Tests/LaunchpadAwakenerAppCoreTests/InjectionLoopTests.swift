import Foundation
import Testing
@testable import LaunchpadAwakenerAppCore

/// Covers the injection loop DockIconOverride hit on 2026-08-14, whose rules this app shares.
///
/// A payload that would not answer was treated as a host that had gone away, so the host was struck
/// off the injected list; the next discovery pass two seconds later saw a target that had never
/// been injected and injected it again. From the log, one full turn of the loop:
///
/// ```
/// 20:49:46  Injected into 51569
/// 20:49:48  Payload in 51569 stopped answering: Peer connection not established
/// 20:49:51  Payload in 51569 did not open its channel
/// 20:49:52  Injected into 51569
/// 20:49:55  Payload in 51569 stopped answering
/// ```
///
/// The interface showed all three of its states at once as a result: a green "Injected into process
/// 51569", an orange "Injected: No", and a "Not injected" banner.
@Suite("Injection loop")
struct InjectionLoopTests {
    /// The regression itself. A silent payload must not retract the injection record — that is what
    /// fed the loop.
    @Test("A live host whose payload stops answering stays on record as injected")
    func silentPayloadDoesNotRetractInjection() {
        let decision = HostRefreshDecision.decide(
            hostIsAlive: true,
            payloadAnswered: false,
            payloadHasEverAnswered: true,
            isWithinHandshakeGracePeriod: false
        )

        #expect(decision == .dropChannelKeepingInjectionOnRecord)
        #expect(decision != .forgetEntirely)
    }

    @Test("A host that has exited is forgotten entirely")
    func deadHostIsForgotten() {
        #expect(
            HostRefreshDecision.decide(
                hostIsAlive: false,
                payloadAnswered: false,
                payloadHasEverAnswered: true,
                isWithinHandshakeGracePeriod: false
            ) == .forgetEntirely
        )

        // Liveness settles it on its own — no combination of the other three can keep a departed
        // host on the books.
        for payloadHasEverAnswered in [true, false] {
            for isWithinHandshakeGracePeriod in [true, false] {
                #expect(
                    HostRefreshDecision.decide(
                        hostIsAlive: false,
                        payloadAnswered: false,
                        payloadHasEverAnswered: payloadHasEverAnswered,
                        isWithinHandshakeGracePeriod: isWithinHandshakeGracePeriod
                    ) == .forgetEntirely
                )
            }
        }
    }

    @Test("A live host with a working payload is left alone")
    func healthyHostIsLeftAlone() {
        #expect(
            HostRefreshDecision.decide(
                hostIsAlive: true,
                payloadAnswered: true,
                payloadHasEverAnswered: true,
                isWithinHandshakeGracePeriod: false
            ) == .keepAsIs
        )
    }

    /// The second half of what the 2026-08-14 log showed. Closing the channel while the payload is
    /// still connecting closes the endpoint it is connecting *to*, so a payload that was seconds
    /// away from answering never gets to — `Listener error: connectionInvalid` on the app side, and
    /// no payload row in the window for the life of that Dock.
    @Test("A freshly injected payload is given time to finish its handshake")
    func freshPayloadIsGivenTimeToHandshake() {
        #expect(
            HostRefreshDecision.decide(
                hostIsAlive: true,
                payloadAnswered: false,
                payloadHasEverAnswered: false,
                isWithinHandshakeGracePeriod: true
            ) == .waitForHandshake
        )
    }

    @Test("The grace period runs out")
    func gracePeriodRunsOut() {
        #expect(
            HostRefreshDecision.decide(
                hostIsAlive: true,
                payloadAnswered: false,
                payloadHasEverAnswered: false,
                isWithinHandshakeGracePeriod: false
            ) == .dropChannelKeepingInjectionOnRecord
        )
    }

    /// A payload that answered once and then stopped is broken, not starting up. The grace period
    /// must not apply to it — otherwise a channel that dies inside the window would be waited on
    /// rather than replaced.
    @Test("The grace period does not apply once a payload has answered")
    func gracePeriodDoesNotApplyAfterFirstAnswer() {
        #expect(
            HostRefreshDecision.decide(
                hostIsAlive: true,
                payloadAnswered: false,
                payloadHasEverAnswered: true,
                isWithinHandshakeGracePeriod: true
            ) == .dropChannelKeepingInjectionOnRecord
        )
    }

    /// The other half of the loop: whatever this returns gets injected, so a host already on record
    /// has to be excluded here just as firmly as it is kept on record there.
    @Test("An already-injected target is never selected for injection")
    func injectedTargetIsNotSelected() {
        let selected = InjectionSelection.processIdentifiersNeedingInjection(
            running: [51569],
            alreadyInjected: [51569],
            beingInjected: []
        )

        #expect(selected.isEmpty)
    }

    @Test("A target with an attempt in flight is not selected again")
    func inFlightTargetIsNotSelected() {
        let selected = InjectionSelection.processIdentifiersNeedingInjection(
            running: [51569],
            alreadyInjected: [],
            beingInjected: [51569]
        )

        #expect(selected.isEmpty)
    }

    @Test("An uninjected target is selected")
    func uninjectedTargetIsSelected() {
        let selected = InjectionSelection.processIdentifiersNeedingInjection(
            running: [1753, 51569],
            alreadyInjected: [1753],
            beingInjected: []
        )

        #expect(selected == [51569])
    }

    /// The loop end to end, as a state machine: refresh a host whose payload is silent, then ask
    /// what the next discovery pass would inject. Before the fix this returned the host every time,
    /// which is the loop; it must now return nothing however many rounds are run.
    @Test("Repeated refreshes of a silent payload never re-select the host")
    func repeatedRefreshesNeverReselect() {
        let hostProcessIdentifier: pid_t = 51569
        var injectedProcessIdentifiers: Set<pid_t> = [hostProcessIdentifier]

        for round in 0..<10 {
            let decision = HostRefreshDecision.decide(
                hostIsAlive: true,
                payloadAnswered: false,
                payloadHasEverAnswered: false,
                // The grace period covers only the first couple of rounds; the rest run past it,
                // which is where the loop used to start.
                isWithinHandshakeGracePeriod: round < 2
            )

            switch decision {
            case .forgetEntirely:
                injectedProcessIdentifiers.remove(hostProcessIdentifier)
            case .keepAsIs, .waitForHandshake, .dropChannelKeepingInjectionOnRecord:
                break
            }

            let wouldInject = InjectionSelection.processIdentifiersNeedingInjection(
                running: [hostProcessIdentifier],
                alreadyInjected: injectedProcessIdentifiers,
                beingInjected: []
            )
            #expect(wouldInject.isEmpty, "a silent payload must not cause its host to be injected again")
        }
    }
}
