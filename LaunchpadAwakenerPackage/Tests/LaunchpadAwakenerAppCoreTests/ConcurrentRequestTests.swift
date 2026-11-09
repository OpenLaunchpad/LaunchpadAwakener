import Foundation
import Testing
@testable import LaunchpadAwakenerAppCore

/// Covers the requests that several parts of the app make at once at launch: the launch sequence,
/// the monitor's first sight of the Dock and its first discovery pass all reach the daemon check and
/// the registry within the same few milliseconds.
@Suite("Concurrent requests")
@MainActor
struct ConcurrentRequestTests {
    /// The regression, from the test Mac's log at 11:24:19: three callers diagnosed the outdated
    /// daemon together, the first reinstalled it, and the other two were told "Reinstalling again in
    /// 60s" — a failure recorded, and a 15-second backoff started, for a daemon that was fine a
    /// second later. Callers that arrive while a check is under way must share its answer.
    @Test("Callers that overlap share one run and its result", .timeLimit(.minutes(1)))
    func overlappingCallersShareOneRun() async {
        let singleFlight = SingleFlight<Int>()
        let counter = RunCounter()

        let first = Task {
            await singleFlight.run {
                counter.runCount += 1
                counter.hasStarted = true
                try? await Task.sleep(for: .milliseconds(300))
                return counter.runCount
            }
        }
        // The second caller arrives while the first run is under way.
        while !counter.hasStarted {
            await Task.yield()
        }
        let second = Task {
            await singleFlight.run {
                counter.runCount += 1
                return counter.runCount
            }
        }

        let results = [await first.value, await second.value]
        #expect(counter.runCount == 1)
        #expect(results == [1, 1])
    }

    @Test("A caller after the run has finished starts a new one")
    func laterCallerStartsAgain() async {
        let singleFlight = SingleFlight<Int>()
        let counter = RunCounter()

        _ = await singleFlight.run {
            counter.runCount += 1
            return counter.runCount
        }
        let second = await singleFlight.run {
            counter.runCount += 1
            return counter.runCount
        }

        #expect(counter.runCount == 2)
        #expect(second == 2)
    }

    @MainActor
    private final class RunCounter {
        var runCount = 0
        var hasStarted = false
    }
}

/// Covers the Docks that Restart Dock is replacing.
@Suite("Restarting targets")
struct RestartingTargetTests {
    /// The regression: Restart Dock forgets the outgoing Dock before signalling it, and a discovery
    /// pass that saw it a moment earlier would find it "missed" and inject into a process that is
    /// shutting down — counting its exit seconds later as a quick exit, on the way to switching
    /// automatic injection off.
    @Test("A Dock being restarted is never selected for injection")
    func targetBeingRestartedIsNotSelected() {
        let selected = InjectionSelection.processIdentifiersNeedingInjection(
            running: [49142, 83832],
            alreadyInjected: [],
            beingInjected: [],
            beingRestarted: [49142]
        )

        #expect(selected == [83832])
    }

    @Test("A child process is terminated")
    func ownProcessIsTerminated() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        #expect(ProcessTermination.terminate(process.processIdentifier) == .terminated)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
    }

    /// Another user's Dock matches the same path under fast user switching. It is not this user's
    /// to restart, and the refusal is not an error worth a red line.
    @Test("Another user's process is left alone without an error")
    func otherUsersProcessIsLeftAlone() {
        // launchd belongs to root.
        #expect(ProcessTermination.terminate(1) == .belongsToAnotherUser)
    }

    @Test("A process that has gone is reported as such")
    func vanishedProcessIsReported() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        #expect(ProcessTermination.terminate(process.processIdentifier) == .alreadyGone)
    }
}
