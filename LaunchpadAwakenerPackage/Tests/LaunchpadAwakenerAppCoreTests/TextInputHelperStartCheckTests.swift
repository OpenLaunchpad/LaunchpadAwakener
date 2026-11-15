import Darwin
import Testing
@testable import LaunchpadAwakenerAppCore

/// The check that launchd starts the input method helper, and the repair when it does not, against a
/// stand-in for launchd: which helpers run, and whether connecting finds the service at all.
@Suite("Checking that launchd starts the input method helper")
@MainActor
struct TextInputHelperStartCheckTests {
    /// Stands in for launchd and the process table: the helpers running, and what connecting does.
    @MainActor
    private final class StandInLaunchd {
        var hasService = true
        /// Started on the first connection when launchd can start the helper.
        var startsHelperOnConnection = true
        var runningHelpers: [pid_t] = []
        private(set) var connectionCount = 0
        private(set) var closedConnectionCount = 0
        private var nextProcessIdentifier: pid_t = 500

        func check(deadline: Duration = .milliseconds(300)) -> TextInputHelperStartCheck {
            TextInputHelperStartCheck(
                connect: { [self] in
                    guard hasService else { return nil }
                    connectionCount += 1
                    if startsHelperOnConnection {
                        runningHelpers.append(nextProcessIdentifier)
                        nextProcessIdentifier += 1
                    }
                    return { [self] in closedConnectionCount += 1 }
                },
                runningHelpers: { [self] in runningHelpers },
                deadline: deadline,
                pollingInterval: .milliseconds(10)
            )
        }
    }

    @Test("a helper launchd starts on connection is found, and the connection is closed")
    func helperStarts() async {
        let launchd = StandInLaunchd()

        #expect(await launchd.check().helperStarts(besides: nil))
        #expect(launchd.connectionCount == 1)
        #expect(launchd.closedConnectionCount == 1)
    }

    @Test("a helper running already counts, without waiting for another")
    func helperRunningAlready() async {
        let launchd = StandInLaunchd()
        launchd.startsHelperOnConnection = false
        launchd.runningHelpers = [77]

        #expect(await launchd.check(deadline: .seconds(60)).helperStarts(besides: nil))
    }

    @Test("no service at launchd means no helper, at once")
    func noService() async {
        let launchd = StandInLaunchd()
        launchd.hasService = false

        #expect(await launchd.check(deadline: .seconds(60)).helperStarts(besides: nil) == false)
    }

    @Test("the helper just ended does not count while it goes away")
    func endedHelperDoesNotCount() async {
        let launchd = StandInLaunchd()
        launchd.startsHelperOnConnection = false
        launchd.runningHelpers = [41]

        #expect(await launchd.check().helperStarts(besides: 41) == false)
    }

    @Test("a helper that starts leaves the agent alone")
    func startsWithoutRepair() async {
        let launchd = StandInLaunchd()
        var registrations = 0

        let outcome = await launchd.check().run(besides: nil) { registrations += 1 }

        #expect(outcome == .starts)
        #expect(registrations == 0)
    }

    @Test("a helper launchd starts only once the agent is registered again is reported so", arguments: [true, false])
    func startsAfterRegisteringAgain(hasService: Bool) async {
        // A job pointing at a missing login item record keeps the service but starts nothing; a missing job
        // has no service at all.
        let launchd = StandInLaunchd()
        launchd.hasService = hasService
        launchd.startsHelperOnConnection = false
        var registrations = 0

        let outcome = await launchd.check().run(besides: nil) {
            registrations += 1
            launchd.hasService = true
            launchd.startsHelperOnConnection = true
        }

        #expect(outcome == .startsAfterRegisteringAgain)
        #expect(registrations == 1)
    }

    @Test("a helper launchd does not start even with the agent registered again is reported so")
    func doesNotStart() async {
        let launchd = StandInLaunchd()
        launchd.startsHelperOnConnection = false
        var registrations = 0

        let outcome = await launchd.check().run(besides: nil) { registrations += 1 }

        #expect(outcome == .doesNotStart)
        #expect(registrations == 1)
    }
}
