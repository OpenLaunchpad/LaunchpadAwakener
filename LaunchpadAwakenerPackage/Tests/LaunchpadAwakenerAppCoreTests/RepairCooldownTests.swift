import Foundation
import Testing
@testable import LaunchpadAwakenerAppCore

/// Covers the rule that replaced "only reinstall the daemon when it answers with the wrong version".
///
/// The bug that motivated it: a launchd job that will not start cannot answer, so it could never be
/// found stale, so the one code path that would have repaired it never ran. The fix removes the
/// error-classification gate entirely and relies on this cooldown to stop a persistent failure from
/// reinstalling on every request — which makes these the tests that hold that reasoning up.
///
/// `recordAttempt` results are bound to a variable before being asserted on throughout: `#expect`
/// decomposes the expression it is handed into a closure over the operands, which cannot call a
/// `mutating` member.
@Suite("Repair cooldown")
struct RepairCooldownTests {
    /// A fixed reference point. Tests must not depend on the wall clock.
    private static let referenceTime = Date(timeIntervalSince1970: 1_000_000)

    @Test("The first attempt is always permitted")
    func firstAttemptIsPermitted() {
        var cooldown = RepairCooldown(interval: 60)
        #expect(cooldown.permitsAttempt(at: Self.referenceTime))

        let didRecord = cooldown.recordAttempt(at: Self.referenceTime)
        #expect(didRecord)
    }

    /// The regression itself: before the cooldown existed, every failing request would have
    /// triggered its own reinstall, and each reinstall costs an unregister, a one-second pause and a
    /// re-register. The monitor's discovery pass alone would have produced one every two seconds.
    @Test("A second attempt inside the interval is refused")
    func secondAttemptWithinIntervalIsRefused() {
        var cooldown = RepairCooldown(interval: 60)
        let didRecordFirst = cooldown.recordAttempt(at: Self.referenceTime)
        #expect(didRecordFirst)

        let oneSecondLater = Self.referenceTime.addingTimeInterval(1)
        #expect(!cooldown.permitsAttempt(at: oneSecondLater))
        let didRecordImmediately = cooldown.recordAttempt(at: oneSecondLater)
        #expect(!didRecordImmediately)

        let didRecordJustInsideTheInterval = cooldown.recordAttempt(
            at: Self.referenceTime.addingTimeInterval(59.9)
        )
        #expect(!didRecordJustInsideTheInterval)
    }

    /// The other half: a daemon that stays broken has to keep getting repair attempts, or the app
    /// is back to needing the user to fix it by hand.
    @Test("An attempt is permitted again once the interval has passed")
    func attemptIsPermittedAfterInterval() {
        var cooldown = RepairCooldown(interval: 60)
        let didRecordFirst = cooldown.recordAttempt(at: Self.referenceTime)
        #expect(didRecordFirst)

        let exactlyOnTheBoundary = Self.referenceTime.addingTimeInterval(60)
        #expect(cooldown.permitsAttempt(at: exactlyOnTheBoundary))
        let didRecordOnBoundary = cooldown.recordAttempt(at: exactlyOnTheBoundary)
        #expect(didRecordOnBoundary)

        // And the clock restarts from the attempt just recorded, not from the first one.
        let didRecordThirtySecondsLater = cooldown.recordAttempt(
            at: exactlyOnTheBoundary.addingTimeInterval(30)
        )
        #expect(!didRecordThirtySecondsLater)

        let didRecordSixtySecondsLater = cooldown.recordAttempt(
            at: exactlyOnTheBoundary.addingTimeInterval(60)
        )
        #expect(didRecordSixtySecondsLater)
    }

    /// A refused attempt must not restart the clock. If it did, a caller retrying in a tight loop
    /// would push the next permitted attempt further away every time and the repair would never run
    /// again — the failure mode this whole mechanism exists to avoid, reintroduced by the mechanism
    /// itself.
    @Test("A refused attempt does not extend the cooldown")
    func refusedAttemptDoesNotExtendCooldown() {
        var cooldown = RepairCooldown(interval: 60)
        let didRecordFirst = cooldown.recordAttempt(at: Self.referenceTime)
        #expect(didRecordFirst)

        for secondsElapsed in stride(from: 1.0, to: 60.0, by: 1.0) {
            let didRecord = cooldown.recordAttempt(at: Self.referenceTime.addingTimeInterval(secondsElapsed))
            #expect(!didRecord, "an attempt \(secondsElapsed)s into the interval should be refused")
        }

        let didRecordAfterInterval = cooldown.recordAttempt(at: Self.referenceTime.addingTimeInterval(60))
        #expect(didRecordAfterInterval)
    }

    @Test("The next permitted time is reported while cooling down, and not otherwise")
    func nextPermittedAttemptIsReportedOnlyWhileCoolingDown() {
        var cooldown = RepairCooldown(interval: 60)
        #expect(cooldown.nextPermittedAttempt(after: Self.referenceTime) == nil)

        let didRecord = cooldown.recordAttempt(at: Self.referenceTime)
        #expect(didRecord)
        #expect(
            cooldown.nextPermittedAttempt(after: Self.referenceTime.addingTimeInterval(10))
                == Self.referenceTime.addingTimeInterval(60)
        )
        #expect(cooldown.nextPermittedAttempt(after: Self.referenceTime.addingTimeInterval(60)) == nil)
    }

    /// Used when the user acts directly — uninstalling the daemon, or restarting the Dock. Whatever
    /// the cooldown was waiting out no longer describes the situation.
    @Test("Resetting permits an attempt immediately")
    func resetPermitsAttemptImmediately() {
        var cooldown = RepairCooldown(interval: 60)
        let didRecord = cooldown.recordAttempt(at: Self.referenceTime)
        #expect(didRecord)
        #expect(!cooldown.permitsAttempt(at: Self.referenceTime.addingTimeInterval(1)))

        cooldown.reset()

        #expect(cooldown.permitsAttempt(at: Self.referenceTime.addingTimeInterval(1)))
    }
}
