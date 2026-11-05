import Foundation
import OSLog
import FilesServiceInterface
import InjectionServiceInterface
import LaunchpadAwakenerShared

/// Drives the whole injection pipeline: stage the payload where the daemon can reach it, inject it
/// into every running target, and re-inject whenever a target restarts.
@Observable
@MainActor
public final class PayloadInjectionCoordinator {
    /// Which injection path to use.
    public enum InjectionMethod: Sendable {
        /// `dlopen` inside the target. Runs the payload's constructor, which is the ordinary path.
        ///
        /// Fails against targets whose sandbox profile denies `file-map-executable` — several Apple
        /// daemons are profiled that way. Use ``memoryRemap`` for those.
        case dynamicLibraryLoad

        /// `mach_vm_remap` the payload into the target and call its entry symbol on a fresh thread.
        ///
        /// Needed for sandbox-profiled targets that cannot `dlopen`. dyld's constructor pass never
        /// runs on a remapped image, so the payload's entry symbol is called directly instead —
        /// see `LaunchpadAwakenerPayload/main.m` for the two-entry contract this relies on.
        case memoryRemap
    }

    public enum CoordinatorError: LocalizedError {
        case payloadMissingFromAppBundle
        case payloadExecutableMissing(bundlePath: String)

        public var errorDescription: String? {
            switch self {
            case .payloadMissingFromAppBundle:
                return "\(InjectionServiceIdentity.payloadFrameworkName).framework is not in the app bundle. Check the app target's Copy Files phase."
            case .payloadExecutableMissing(let bundlePath):
                return "No executable inside \(bundlePath)."
            }
        }
    }

    /// What ``injectIntoRunningTargets()`` did, so the interface can say so.
    public enum InjectionOutcome: Sendable, Equatable {
        /// Nothing matched the target rule, so there was nothing to inject into.
        case noTargetRunning
        /// Every running target had already been injected during this session.
        case alreadyInjected(processIdentifiers: [pid_t])
        case injected(processIdentifiers: [pid_t])
        case failed(description: String)

        /// One line suitable for display.
        public var summary: String {
            switch self {
            case .noTargetRunning:
                return "No target process is running."
            case .alreadyInjected(let processIdentifiers):
                return "Already injected into \(Self.describe(processIdentifiers)) earlier in this session."
            case .injected(let processIdentifiers):
                return "Injected into \(Self.describe(processIdentifiers))."
            case .failed(let description):
                return description
            }
        }

        public var isFailure: Bool {
            switch self {
            case .failed, .noTargetRunning:
                return true
            case .injected, .alreadyInjected:
                return false
            }
        }

        private static func describe(_ processIdentifiers: [pid_t]) -> String {
            let joinedIdentifiers = processIdentifiers.map(String.init).joined(separator: ", ")
            return processIdentifiers.count == 1 ? "process \(joinedIdentifiers)" : "processes \(joinedIdentifiers)"
        }
    }

    private static let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakener", category: "PayloadInjectionCoordinator")

    /// Process identifiers this app has injected into during this session.
    public private(set) var injectedProcessIdentifiers: Set<pid_t> = []

    /// Result of the most recent explicit injection request. Nil until one has been made.
    ///
    /// Automatic re-injection deliberately does not touch this: it fires without the user asking, so
    /// overwriting what they last did would make the interface change under them.
    public private(set) var lastInjectionOutcome: InjectionOutcome?

    /// Most recent failure, cleared on the next successful operation. For display.
    public private(set) var lastErrorDescription: String?

    /// Whether automatic re-injection is running.
    public private(set) var isAutomaticInjectionEnabled: Bool = false

    /// True while an explicit injection request is in flight.
    public private(set) var isInjecting: Bool = false

    private let daemonController: PrivilegedDaemonController
    private let injectionMethod: InjectionMethod
    private let processMonitor: TargetProcessMonitor

    public init(
        daemonController: PrivilegedDaemonController,
        targetMatchingRule: TargetProcessMonitor.MatchingRule,
        injectionMethod: InjectionMethod = .dynamicLibraryLoad
    ) {
        self.daemonController = daemonController
        self.injectionMethod = injectionMethod
        self.processMonitor = TargetProcessMonitor(matchingRule: targetMatchingRule)

        processMonitor.onProcessStarted = { [weak self] processIdentifier in
            Task { @MainActor in
                await self?.injectIfNeeded(intoProcessIdentifier: processIdentifier)
            }
        }
        processMonitor.onProcessExited = { [weak self] processIdentifier in
            Task { @MainActor in
                self?.recordExit(ofProcessIdentifier: processIdentifier)
            }
        }
    }

    // MARK: - Payload staging

    /// Path the payload executable is injected from, once staged.
    public var stagedPayloadExecutableURL: URL {
        InjectionServiceIdentity.payloadInstallationDirectory
            .appendingPathComponent("\(InjectionServiceIdentity.payloadFrameworkName).framework", isDirectory: true)
            .appendingPathComponent("Versions/A/\(InjectionServiceIdentity.payloadFrameworkName)", isDirectory: false)
    }

    public var isPayloadStaged: Bool {
        FileManager.default.fileExists(atPath: stagedPayloadExecutableURL.path)
    }

    /// Copies the payload framework out of the app bundle into the root-owned staging directory.
    ///
    /// Re-running this replaces whatever is there, which is what you want after a rebuild — the
    /// staged copy is a snapshot, not a link, so a stale one would keep being injected forever.
    public func stagePayload() async throws {
        guard let bundledPayloadURL = Bundle.main.url(
            forResource: InjectionServiceIdentity.payloadFrameworkName,
            withExtension: "framework"
        ) else {
            throw CoordinatorError.payloadMissingFromAppBundle
        }

        let destinationDirectory = InjectionServiceIdentity.payloadInstallationDirectory
        let destinationFrameworkURL = destinationDirectory
            .appendingPathComponent(bundledPayloadURL.lastPathComponent, isDirectory: true)

        do {
            try await daemonController.send(
                request: FileOperationRequest(
                    operation: .createDirectory(url: destinationDirectory, isIntermediateDirectories: true)
                )
            )
            // Copy refuses to overwrite, so clear the previous staging first. A missing path is not
            // an error worth surfacing — that is the normal first-run state.
            _ = try? await daemonController.send(
                request: FileOperationRequest(operation: .remove(url: destinationFrameworkURL))
            )
            try await daemonController.send(
                request: FileOperationRequest(
                    operation: .copy(from: bundledPayloadURL, to: destinationFrameworkURL)
                )
            )
            lastErrorDescription = nil
            Self.logger.info("Staged payload at \(destinationFrameworkURL.path, privacy: .public)")
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    // MARK: - Injection

    /// Injects into every target running right now that has not been injected yet.
    ///
    /// Targets are found by scanning the process table rather than by reading what
    /// ``TargetProcessMonitor`` has discovered, because the monitor only discovers anything once
    /// automatic injection has been switched on — consulting it here made this do nothing at all,
    /// silently, whenever the switch was off.
    @discardableResult
    public func injectIntoRunningTargets() async -> InjectionOutcome {
        isInjecting = true
        defer { isInjecting = false }

        let runningProcessIdentifiers = processMonitor.currentlyRunningTargetProcessIdentifiers()

        guard !runningProcessIdentifiers.isEmpty else {
            return record(outcome: .noTargetRunning)
        }

        var newlyInjectedProcessIdentifiers: [pid_t] = []
        var previouslyInjectedProcessIdentifiers: [pid_t] = []
        var failureDescriptions: [String] = []

        for processIdentifier in runningProcessIdentifiers.sorted() {
            guard !injectedProcessIdentifiers.contains(processIdentifier) else {
                previouslyInjectedProcessIdentifiers.append(processIdentifier)
                continue
            }

            do {
                try await inject(intoProcessIdentifier: processIdentifier)
                newlyInjectedProcessIdentifiers.append(processIdentifier)
            } catch {
                failureDescriptions.append(error.localizedDescription)
            }
        }

        if !failureDescriptions.isEmpty {
            return record(outcome: .failed(description: failureDescriptions.joined(separator: "\n")))
        }
        if !newlyInjectedProcessIdentifiers.isEmpty {
            return record(outcome: .injected(processIdentifiers: newlyInjectedProcessIdentifiers))
        }
        return record(outcome: .alreadyInjected(processIdentifiers: previouslyInjectedProcessIdentifiers))
    }

    /// Injects into one process, unless this session already did. Never throws; for the monitor.
    ///
    /// The guard is not an optimisation — injecting the same payload twice into one process loads
    /// two copies of the hooks, and the second install would capture the first's replacement as its
    /// "original", chaining them.
    public func injectIfNeeded(intoProcessIdentifier processIdentifier: pid_t) async {
        guard !injectedProcessIdentifiers.contains(processIdentifier) else { return }

        do {
            try await inject(intoProcessIdentifier: processIdentifier)
        } catch {
            lastErrorDescription = error.localizedDescription
            Self.logger.error(
                "Injection into \(processIdentifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Whether this run of the app has staged its own payload yet.
    ///
    /// A staged copy left by an earlier build still exists on disk, so `isPayloadStaged` alone
    /// would keep injecting that old build after every rebuild.
    private var hasStagedPayloadInThisRun = false

    /// Stages the payload if needed and injects it into one process. Throws so callers can report.
    private func inject(intoProcessIdentifier processIdentifier: pid_t) async throws {
        if !hasStagedPayloadInThisRun || !isPayloadStaged {
            try await stagePayload()
            hasStagedPayloadInThisRun = true
        }

        let payloadURL = stagedPayloadExecutableURL
        switch injectionMethod {
        case .dynamicLibraryLoad:
            try await daemonController.send(
                request: InjectApplicationRequest(pid: processIdentifier, dylibURL: payloadURL)
            )
        case .memoryRemap:
            try await daemonController.send(
                request: InjectApplicationViaRemapRequest(
                    pid: processIdentifier,
                    payloadURL: payloadURL,
                    entrySymbol: InjectionServiceIdentity.payloadRemapEntrySymbol
                )
            )
        }

        injectedProcessIdentifiers.insert(processIdentifier)
        injectionDatesByProcessIdentifier[processIdentifier] = Date()
        lastErrorDescription = nil
        Self.logger.info("Injected into \(processIdentifier, privacy: .public)")
    }

    private func record(outcome: InjectionOutcome) -> InjectionOutcome {
        lastInjectionOutcome = outcome
        lastErrorDescription = outcome.isFailure ? outcome.summary : nil

        if outcome.isFailure {
            Self.logger.error("Injection request: \(outcome.summary, privacy: .public)")
        } else {
            Self.logger.info("Injection request: \(outcome.summary, privacy: .public)")
        }

        return outcome
    }

    // MARK: - Automatic re-injection

    private static let automaticInjectionPreferenceKey = "AutomaticInjectionEnabled"

    /// Whether automatic injection should run: on unless it was switched off, by the user or by the
    /// quick-exit guard. Re-injecting after every Dock restart is what makes the replacement stick.
    public var prefersAutomaticInjection: Bool {
        UserDefaults.standard.object(forKey: Self.automaticInjectionPreferenceKey) as? Bool ?? true
    }

    /// Starts watching for the target and injecting as it appears, and remembers the choice.
    public func startAutomaticInjection() {
        UserDefaults.standard.set(true, forKey: Self.automaticInjectionPreferenceKey)
        guard !isAutomaticInjectionEnabled else { return }
        consecutiveQuickExitCount = 0
        isAutomaticInjectionEnabled = true
        processMonitor.start()
    }

    /// Stops automatic injection, and remembers the choice across launches.
    public func stopAutomaticInjection() {
        UserDefaults.standard.set(false, forKey: Self.automaticInjectionPreferenceKey)
        guard isAutomaticInjectionEnabled else { return }
        isAutomaticInjectionEnabled = false
        processMonitor.stop()
    }

    // MARK: - Quick-exit guard

    /// A target that exits this soon after being injected counts as brought down by the payload.
    private static let quickExitInterval: TimeInterval = 15

    /// This many quick exits in a row switch automatic injection off.
    private static let quickExitLimit = 3

    private var injectionDatesByProcessIdentifier: [pid_t: Date] = [:]
    private var consecutiveQuickExitCount = 0

    /// Stops a crash loop. With automatic injection on, a payload that crashes the Dock as it loads
    /// would be injected into every relaunched Dock, again and again; after `quickExitLimit` quick
    /// exits in a row automatic injection switches itself off and says why.
    private func recordExit(ofProcessIdentifier processIdentifier: pid_t) {
        injectedProcessIdentifiers.remove(processIdentifier)
        guard let injectionDate = injectionDatesByProcessIdentifier.removeValue(forKey: processIdentifier) else { return }

        if Date().timeIntervalSince(injectionDate) < Self.quickExitInterval {
            consecutiveQuickExitCount += 1
        } else {
            consecutiveQuickExitCount = 0
        }
        guard consecutiveQuickExitCount >= Self.quickExitLimit, isAutomaticInjectionEnabled else { return }

        stopAutomaticInjection()
        lastErrorDescription = "The target quit within \(Int(Self.quickExitInterval)) seconds of being injected \(Self.quickExitLimit) times in a row, so automatic injection is now off. Fix the payload, then switch it back on."
        Self.logger.error("Automatic injection switched off after \(Self.quickExitLimit, privacy: .public) quick exits in a row")
    }
}
