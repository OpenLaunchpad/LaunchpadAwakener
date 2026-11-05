import Foundation
import Darwin
import OSLog

/// Watches for a target process starting and exiting, so the app can inject as soon as the
/// target appears and re-inject after the target restarts.
///
/// Re-injection matters more than it sounds: system processes get relaunched constantly — by
/// `launchd` after a crash, by the user running `killall`, by logging out and back in — and an
/// injected payload does not survive any of that. Without a monitor, the app's effect silently
/// stops applying until someone notices.
///
/// Discovery is a poll rather than an event subscription. macOS has no unprivileged notification
/// for "any process launched"; `NSWorkspace` only reports regular applications, which excludes
/// most interesting targets (daemons, agents, background-only processes like the Dock). Exit,
/// however, *is* observable exactly, so the monitor polls to find a process and then hands each
/// discovered identifier to a `DispatchSource` that fires precisely on exit.
/// Thread safety: every piece of mutable state is confined to `synchronizationQueue`, which is why
/// the `@unchecked` conformance is sound. The two callback properties are the exception — set them
/// before calling ``start()`` and do not touch them afterwards.
public final class TargetProcessMonitor: @unchecked Sendable {
    /// How to recognise the target.
    public enum MatchingRule: Sendable {
        /// Full path of the executable, compared exactly. Prefer this — it cannot be spoofed by an
        /// unrelated process that happens to share a name.
        case executablePath(String)
        /// Last path component of the executable, compared exactly.
        case executableName(String)
    }

    private static let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakener", category: "TargetProcessMonitor")

    public let matchingRule: MatchingRule

    /// Called on `callbackQueue` for every newly discovered target process.
    public var onProcessStarted: (@Sendable (pid_t) -> Void)?

    /// Called on `callbackQueue` after a tracked target process exits.
    public var onProcessExited: (@Sendable (pid_t) -> Void)?

    private let callbackQueue: DispatchQueue
    private let synchronizationQueue = DispatchQueue(label: "com.MxIris.LaunchpadAwakener.TargetProcessMonitor")

    private var discoveryTimer: DispatchSourceTimer?
    private var exitSourcesByProcessIdentifier: [pid_t: DispatchSourceProcess] = [:]

    public init(matchingRule: MatchingRule, callbackQueue: DispatchQueue = .main) {
        self.matchingRule = matchingRule
        self.callbackQueue = callbackQueue
    }

    deinit {
        // Touch only the timer and sources; cancelling them is safe from any thread.
        discoveryTimer?.cancel()
        exitSourcesByProcessIdentifier.values.forEach { $0.cancel() }
    }

    /// Starts discovery. Already-running target processes are reported immediately.
    public func start(discoveryInterval: DispatchTimeInterval = .seconds(2)) {
        synchronizationQueue.async { [self] in
            guard discoveryTimer == nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: synchronizationQueue)
            timer.schedule(deadline: .now(), repeating: discoveryInterval)
            timer.setEventHandler { [weak self] in
                self?.discoverMatchingProcesses()
            }
            discoveryTimer = timer
            timer.activate()
        }
    }

    public func stop() {
        synchronizationQueue.async { [self] in
            discoveryTimer?.cancel()
            discoveryTimer = nil
            exitSourcesByProcessIdentifier.values.forEach { $0.cancel() }
            exitSourcesByProcessIdentifier.removeAll()
        }
    }

    /// Identifiers the monitor has discovered and is watching for exit.
    ///
    /// Empty until ``start()`` has run a discovery pass, so this answers "what is the monitor
    /// watching", not "what is running". Use ``currentlyRunningTargetProcessIdentifiers()`` for the
    /// latter.
    public var trackedProcessIdentifiers: [pid_t] {
        synchronizationQueue.sync { Array(exitSourcesByProcessIdentifier.keys) }
    }

    /// Scans the process table and returns every matching process running right now.
    ///
    /// Deliberately independent of ``start()``: acting on the target at the user's request must not
    /// depend on the monitor having been switched on, and reading ``trackedProcessIdentifiers``
    /// instead would silently do nothing whenever it has not.
    public func currentlyRunningTargetProcessIdentifiers() -> [pid_t] {
        Self.allProcessIdentifiers().filter { processIdentifier in
            guard let executablePath = Self.executablePath(forProcessIdentifier: processIdentifier) else { return false }
            return matches(executablePath: executablePath)
        }
    }

    // MARK: - Discovery

    /// Runs on `synchronizationQueue`.
    private func discoverMatchingProcesses() {
        for processIdentifier in currentlyRunningTargetProcessIdentifiers() {
            guard exitSourcesByProcessIdentifier[processIdentifier] == nil else { continue }

            beginTrackingExit(ofProcessIdentifier: processIdentifier)
            Self.logger.info("Target process started: \(processIdentifier, privacy: .public)")
            callbackQueue.async { [onProcessStarted] in
                onProcessStarted?(processIdentifier)
            }
        }
    }

    private func matches(executablePath: String) -> Bool {
        switch matchingRule {
        case .executablePath(let expectedPath):
            return executablePath == expectedPath
        case .executableName(let expectedName):
            return (executablePath as NSString).lastPathComponent == expectedName
        }
    }

    /// Runs on `synchronizationQueue`.
    private func beginTrackingExit(ofProcessIdentifier processIdentifier: pid_t) {
        let exitSource = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: synchronizationQueue
        )
        exitSource.setEventHandler { [weak self] in
            guard let self else { return }
            exitSourcesByProcessIdentifier[processIdentifier]?.cancel()
            exitSourcesByProcessIdentifier[processIdentifier] = nil
            Self.logger.info("Target process exited: \(processIdentifier, privacy: .public)")
            callbackQueue.async { [onProcessExited] in
                onProcessExited?(processIdentifier)
            }
        }
        exitSourcesByProcessIdentifier[processIdentifier] = exitSource
        exitSource.activate()
    }

    // MARK: - Process enumeration

    private static func allProcessIdentifiers() -> [pid_t] {
        let requiredByteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredByteCount > 0 else { return [] }

        // proc_listpids reports a byte count, not an element count. Round up by one element so a
        // process that spawns between the sizing call and the fetching call still fits.
        let capacity = Int(requiredByteCount) / MemoryLayout<pid_t>.size + 1
        var identifiers = [pid_t](repeating: 0, count: capacity)
        let writtenByteCount = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &identifiers,
            Int32(capacity * MemoryLayout<pid_t>.size)
        )
        guard writtenByteCount > 0 else { return [] }

        let writtenElementCount = Int(writtenByteCount) / MemoryLayout<pid_t>.size
        // The kernel zero-fills unused slots; a zero identifier is never a real process.
        return identifiers.prefix(writtenElementCount).filter { $0 != 0 }
    }

    private static func executablePath(forProcessIdentifier processIdentifier: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro, so it does not cross into Swift. Its definition is
        // 4 * MAXPATHLEN, and proc_pidpath rejects anything smaller.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        // proc_pidpath returns the byte count it wrote, excluding the terminator, so decoding
        // exactly that many bytes avoids both the deprecated array overload of String(cString:) and
        // any dependence on the terminator being where we expect.
        let pathBytes = pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }
}
