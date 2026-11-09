import Foundation
import Testing
@testable import LaunchpadAwakenerAppCore

/// Covers the discovery callback that lets failed injections be retried, using real processes rather than a fake
/// clock or an injected process table — the thing being verified is what the kernel reports.
@Suite("Target process monitor", .serialized)
struct TargetProcessMonitorTests {
    /// `sleep` is used as the stand-in target: trivially spawnable, does nothing, and exits on
    /// command. Matched by full path so an unrelated process merely *named* sleep cannot be picked
    /// up, which is the same rule the app applies to the Dock.
    private static let targetExecutablePath = "/bin/sleep"

    /// Collects callbacks from the monitor's queue for an `async` test to read.
    private final class CallbackRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var startedProcessIdentifiers: [pid_t] = []
        private var exitedProcessIdentifiers: [pid_t] = []
        private var discoveryPasses: [[pid_t]] = []

        func recordStart(_ processIdentifier: pid_t) {
            lock.withLock { startedProcessIdentifiers.append(processIdentifier) }
        }

        func recordExit(_ processIdentifier: pid_t) {
            lock.withLock { exitedProcessIdentifiers.append(processIdentifier) }
        }

        func recordDiscoveryPass(_ processIdentifiers: [pid_t]) {
            lock.withLock { discoveryPasses.append(processIdentifiers) }
        }

        func startCount(of processIdentifier: pid_t) -> Int {
            lock.withLock { startedProcessIdentifiers.filter { $0 == processIdentifier }.count }
        }

        func hasSeenExit(of processIdentifier: pid_t) -> Bool {
            lock.withLock { exitedProcessIdentifiers.contains(processIdentifier) }
        }

        func discoveryPassCount(including processIdentifier: pid_t) -> Int {
            lock.withLock { discoveryPasses.filter { $0.contains(processIdentifier) }.count }
        }
    }

    /// The regression this exists for: `onProcessStarted` fires once per process and never again,
    /// so a target the app failed to inject was never mentioned a second time and stayed uninjected
    /// for the rest of its life, however long ago the cause of the failure had been fixed.
    /// `onDiscoveryPass` reports the whole current set every tick, which is what lets the
    /// coordinator retry.
    @Test("Discovery passes keep reporting a target, while onProcessStarted fires once", .timeLimit(.minutes(1)))
    func discoveryPassReportsTargetRepeatedly() async throws {
        let sleepProcess = try Self.startSleepProcess()
        defer { Self.terminate(sleepProcess) }

        let recorder = CallbackRecorder()
        let monitor = TargetProcessMonitor(matchingRule: .executablePath(Self.targetExecutablePath))
        monitor.onProcessStarted = { recorder.recordStart($0) }
        monitor.onDiscoveryPass = { recorder.recordDiscoveryPass($0) }
        defer { monitor.stop() }

        monitor.start(discoveryInterval: .milliseconds(100))

        let processIdentifier = sleepProcess.processIdentifier
        try await Self.waitUntil("the target is reported by at least three discovery passes") {
            recorder.discoveryPassCount(including: processIdentifier) >= 3
        }

        // The point of the new callback: repeated reports, from a process announced exactly once.
        #expect(recorder.startCount(of: processIdentifier) == 1)
    }

    @Test("A target that exits is reported once, and stops appearing in discovery passes", .timeLimit(.minutes(1)))
    func exitIsReportedAndTargetDisappears() async throws {
        let sleepProcess = try Self.startSleepProcess()

        let recorder = CallbackRecorder()
        let monitor = TargetProcessMonitor(matchingRule: .executablePath(Self.targetExecutablePath))
        monitor.onProcessStarted = { recorder.recordStart($0) }
        monitor.onProcessExited = { recorder.recordExit($0) }
        monitor.onDiscoveryPass = { recorder.recordDiscoveryPass($0) }
        defer { monitor.stop() }

        monitor.start(discoveryInterval: .milliseconds(100))

        let processIdentifier = sleepProcess.processIdentifier
        try await Self.waitUntil("the target is discovered") {
            recorder.startCount(of: processIdentifier) == 1
        }

        Self.terminate(sleepProcess)

        try await Self.waitUntil("the exit is reported") {
            recorder.hasSeenExit(of: processIdentifier)
        }

        let passesBeforeSettling = recorder.discoveryPassCount(including: processIdentifier)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(recorder.discoveryPassCount(including: processIdentifier) == passesBeforeSettling)
    }

    /// `currentlyRunningTargetProcessIdentifiers()` is what the "Inject Now" button uses, and it has
    /// to work without the monitor having been started — the button must not silently do nothing
    /// just because automatic injection is switched off.
    @Test("Running targets are found without starting the monitor", .timeLimit(.minutes(1)))
    func runningTargetsAreFoundWithoutStarting() throws {
        let sleepProcess = try Self.startSleepProcess()
        defer { Self.terminate(sleepProcess) }

        let monitor = TargetProcessMonitor(matchingRule: .executablePath(Self.targetExecutablePath))

        #expect(monitor.currentlyRunningTargetProcessIdentifiers().contains(sleepProcess.processIdentifier))
        #expect(monitor.trackedProcessIdentifiers.isEmpty)
    }

    @Test("A rule that matches nothing finds nothing")
    func unmatchedRuleFindsNothing() {
        let monitor = TargetProcessMonitor(
            matchingRule: .executablePath("/nonexistent/executable/that/is/not/running")
        )

        #expect(monitor.currentlyRunningTargetProcessIdentifiers().isEmpty)
    }

    // MARK: - Helpers

    private static func startSleepProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: targetExecutablePath)
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    /// Polls `condition` until it holds, or fails the test after `timeout`.
    ///
    /// Polling rather than a continuation because the values being waited on are produced on the
    /// monitor's own queues, and bridging every one of them into an `AsyncSequence` would be more
    /// machinery than the thing under test.
    private static func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(10),
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Timed out waiting for \(description)")
    }
}
