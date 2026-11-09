import Foundation
import Testing
@testable import LaunchpadAwakenerAppCore

/// Covers the pieces that decide when displayed state has stopped being true.
///
/// Every stale line DockIconOverride's window once showed came from state that was written once and
/// never revisited: a dead process identifier under "Injected", and an outcome line describing an
/// injection into a process that had since exited.
@Suite("Stale state")
struct StaleStateTests {
    @Test("This process is alive")
    func currentProcessIsAlive() {
        #expect(ProcessLiveness.isAlive(ProcessInfo.processInfo.processIdentifier))
    }

    @Test("A process that has exited is not alive")
    func exitedProcessIsNotAlive() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        let processIdentifier = process.processIdentifier
        process.waitUntilExit()

        // The child has been reaped by `waitUntilExit`, so the identifier no longer resolves.
        #expect(!ProcessLiveness.isAlive(processIdentifier))
    }

    /// `kill` reads 0 as "every process in my group" and negative values as a process group, so
    /// passing either through would answer a question nobody asked — and would report "alive" for
    /// an identifier that never named a process.
    @Test("Non-positive identifiers are never alive", arguments: [pid_t(0), pid_t(-1), pid_t(-1000)])
    func nonPositiveIdentifiersAreNotAlive(processIdentifier: pid_t) {
        #expect(!ProcessLiveness.isAlive(processIdentifier))
    }

    /// The outcome has to say which processes it is about, or there is no way to notice that they
    /// have all gone and the line should be retired.
    @Test("Outcomes report the processes they describe")
    func outcomesReportTheirProcesses() {
        typealias Outcome = PayloadInjectionCoordinator.InjectionOutcome

        #expect(Outcome.injected(processIdentifiers: [11, 22]).processIdentifiers == [11, 22])
        #expect(Outcome.alreadyInjected(processIdentifiers: [33]).processIdentifiers == [33])
        // Neither of these is about a live process, so neither can go stale by one exiting.
        #expect(Outcome.noTargetRunning.processIdentifiers.isEmpty)
        #expect(Outcome.failed(description: "nope").processIdentifiers.isEmpty)
    }

    /// Automatic re-injection used to be excluded from the displayed outcome so the interface would
    /// not change unprompted. What that actually produced was the previous Dock's result sitting
    /// there forever. It is shown now, and labelled, so "I did this" stays distinguishable from
    /// "this happened".
    @Test("Automatic outcomes are labelled and user-requested ones are not")
    func automaticOutcomesAreLabelled() {
        typealias Report = PayloadInjectionCoordinator.InjectionReport
        let outcome = PayloadInjectionCoordinator.InjectionOutcome.injected(processIdentifiers: [42])

        let userRequested = Report(outcome: outcome, trigger: .userRequested)
        let automatic = Report(outcome: outcome, trigger: .automatic)

        #expect(userRequested.summary == outcome.summary)
        #expect(automatic.summary != outcome.summary)
        #expect(automatic.summary.hasPrefix("Automatically:"))
        // The sentence still reads as one: the borrowed clause is lowercased where it is joined.
        #expect(automatic.summary.contains("injected into process 42"))
    }

    @Test("Failure is carried through the report")
    func failureIsCarriedThroughTheReport() {
        typealias Report = PayloadInjectionCoordinator.InjectionReport

        let failed = Report(
            outcome: .failed(description: "The daemon is registered but unreachable"),
            trigger: .automatic
        )
        #expect(failed.isFailure)

        let succeeded = Report(outcome: .injected(processIdentifiers: [1]), trigger: .automatic)
        #expect(!succeeded.isFailure)

        // "Nothing was running" is reported as a failure on purpose: the user asked for an
        // injection and did not get one, which is worth a red line rather than a green one.
        #expect(Report(outcome: .noTargetRunning, trigger: .userRequested).isFailure)
    }
}
