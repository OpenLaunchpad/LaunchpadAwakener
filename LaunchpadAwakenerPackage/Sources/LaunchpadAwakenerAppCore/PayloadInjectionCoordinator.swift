import Foundation
import Darwin
import FilesServiceInterface
import InjectionServiceInterface
import InjectedEndpointRegistryServiceInterface
import LaunchpadAwakenerPayloadInterface
import LaunchpadAwakenerShared
import OSToolbox

/// Drives the whole injection pipeline: stage the payload where the daemon can reach it, inject it
/// into every running target, re-inject whenever a target restarts, and keep what the window says
/// about the payloads true.
///
/// Most of its rules come from DockIconOverride, built from the same scaffold, where each one was
/// learned the hard way; the comments say what went wrong without them.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "PayloadInjectionCoordinator")
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

    /// What asked for an injection.
    ///
    /// Recorded alongside the outcome so the interface can say "this is what your button did"
    /// separately from "this happened while you were not looking".
    public enum InjectionTrigger: Sendable, Equatable {
        case userRequested
        case automatic
    }

    /// What an injection attempt did, so the interface can say so.
    public enum InjectionOutcome: Sendable, Equatable {
        /// Nothing matched the target rule, so there was nothing to inject into.
        case noTargetRunning
        /// Every running target had already been injected.
        case alreadyInjected(processIdentifiers: [pid_t])
        case injected(processIdentifiers: [pid_t])
        case failed(description: String)

        /// One line suitable for display.
        public var summary: String {
            switch self {
            case .noTargetRunning:
                return "No Dock process is running."
            case .alreadyInjected(let processIdentifiers):
                return "Already injected into \(Self.describe(processIdentifiers))."
            case .injected(let processIdentifiers):
                return "Injected into \(Self.describe(processIdentifiers))."
            case .failed(let description):
                return description
            }
        }

        /// "Nothing was running" counts as a failure on purpose: the user asked for an injection and
        /// did not get one, which is worth a red line rather than a green one.
        public var isFailure: Bool {
            switch self {
            case .failed, .noTargetRunning:
                return true
            case .injected, .alreadyInjected:
                return false
            }
        }

        /// Which processes this outcome is about, if any. Used to expire it once they are gone.
        var processIdentifiers: [pid_t] {
            switch self {
            case .injected(let processIdentifiers), .alreadyInjected(let processIdentifiers):
                return processIdentifiers
            case .noTargetRunning, .failed:
                return []
            }
        }

        private static func describe(_ processIdentifiers: [pid_t]) -> String {
            let joinedIdentifiers = processIdentifiers.map(String.init).joined(separator: ", ")
            return processIdentifiers.count == 1 ? "process \(joinedIdentifiers)" : "processes \(joinedIdentifiers)"
        }
    }

    /// An outcome together with what asked for it.
    public struct InjectionReport: Sendable, Equatable {
        public let outcome: InjectionOutcome
        public let trigger: InjectionTrigger

        public var summary: String {
            switch trigger {
            case .userRequested:
                return outcome.summary
            case .automatic:
                return "Automatically: \(outcome.summary.prefix(1).lowercased())\(outcome.summary.dropFirst())"
            }
        }

        public var isFailure: Bool { outcome.isFailure }
    }

    /// One payload that answered, described for display.
    ///
    /// Deliberately not the wire type: keeping `LaunchpadAwakenerPayloadInterface` out of this
    /// module's public surface lets the app target link `LaunchpadAwakenerAppCore` and nothing else.
    public struct ResidentPayload: Sendable, Equatable, Identifiable {
        /// What became of the payload's hooks.
        public enum HookState: Sendable, Equatable {
            case installed(hookCount: Int)
            /// The Dock's methods do not match the signatures the payload recorded for them.
            case incompatibleDockMethods
            /// A hook failed validation, so none were installed.
            case failed(description: String)
        }

        /// Whether the payload could reach the Dock globals the replica needs, when last asked.
        public enum GlobalsReachability: Sendable, Equatable {
            /// Every global the replica needs was found.
            case reachable
            /// What could not be found, named the way a person would read it.
            case unreachable(missingClassNames: [String])
        }

        public let hostProcessIdentifier: pid_t
        public let hostProcessName: String
        /// `LC_UUID` of the resident payload image.
        public let imageUUID: UUID
        /// Not the build in this app's bundle. Re-injecting will not replace it.
        public let isStale: Bool
        public let hookState: HookState
        /// `CFBundleVersion` of the Dock the payload is attached to.
        public let dockBundleVersion: String
        /// The macOS that Dock is running on, such as `27.2 (26B123)`.
        public let dockSystemRelease: String
        /// Whether the payload could reach the Dock globals the replica needs, when last asked.
        ///
        /// Independent of ``hookState``: the hooks decide where the Launchpad key goes, these give the
        /// geometry and material needed to sit against the Dock. Without them the replica still opens.
        public let dockGlobalsReachability: GlobalsReachability

        /// True when the replica has everything it needs to sit flush against the Dock.
        public var areDockGlobalsReachable: Bool { dockGlobalsReachability == .reachable }

        public var id: pid_t { hostProcessIdentifier }

        public var areHooksInstalled: Bool {
            if case .installed(let hookCount) = hookState { return hookCount > 0 }
            return false
        }
    }

    /// Process identifiers known to hold the payload: injected this run, or found by reconnecting.
    public private(set) var injectedProcessIdentifiers: Set<pid_t> = []

    /// Processes with an injection attempt in flight right now.
    ///
    /// This is also what makes "check whether it is injected, then inject it" safe. The button and
    /// the process monitor reach the same code, and both used to test ``injectedProcessIdentifiers``
    /// and then `await` before inserting into it — so a target could get past the check twice.
    /// Membership here is decided and recorded before the first suspension point, which on the main
    /// actor means no second caller can be in between.
    public private(set) var processIdentifiersBeingInjected: Set<pid_t> = []

    /// Result of the most recent injection, whoever asked for it, labelled with what asked.
    ///
    /// Leaving automatic injections out — so the window would not change unprompted — left the
    /// previous Dock's result on display indefinitely, describing a process that no longer existed.
    public private(set) var lastInjectionReport: InjectionReport?

    /// Most recent failure, cleared on the next successful operation. For display.
    public private(set) var lastErrorDescription: String?

    /// Whether automatic re-injection should happen. Persisted across launches; on by default.
    ///
    /// Deliberately separate from ``isMonitoringTargets``. Folding "what the user asked for" and
    /// "what the monitor is doing" into one flag makes launch-time activation impossible: reading the
    /// preference into the flag on init makes every later start call return early on its own guard,
    /// and the monitor never runs.
    public private(set) var isAutomaticInjectionEnabled: Bool

    /// Whether the process monitor is running right now.
    @ObservationIgnored
    private var isMonitoringTargets: Bool = false

    /// True while any injection attempt is in flight, automatic ones included.
    public var isInjecting: Bool { !processIdentifiersBeingInjected.isEmpty }

    /// True while waiting for a deliberately restarted Dock to come back.
    ///
    /// Separate from ``isInjecting`` because nothing is being injected yet — the target does not
    /// exist. Both feed ``isBusy``: from the outside this is one continuous "working on it".
    public private(set) var isWaitingForTargetRestart: Bool = false

    /// Whether anything the user should wait for is happening.
    public var isBusy: Bool { isInjecting || isWaitingForTargetRestart }

    /// Called after every successful injection. The app uses it to turn launching at login on the
    /// first time the tool has worked.
    @ObservationIgnored
    public var onInjectionSucceeded: (@MainActor () -> Void)?

    /// Backs off automatic retries after a failure.
    ///
    /// The monitor's discovery pass runs every couple of seconds. Without this, a daemon that is
    /// unusable would produce a failing injection on every tick, filling the log and the error line
    /// with the same sentence forever. Recorded on failure and reset on success.
    @ObservationIgnored
    private var automaticRetryCooldown = RepairCooldown(interval: PayloadInjectionCoordinator.automaticRetryInterval)

    /// Minimum gap between automatic retries after a failure.
    private static let automaticRetryInterval: TimeInterval = 15

    @ObservationIgnored
    private var quickExitGuard = QuickExitGuard()

    /// Docks Restart Dock has signalled and that have not exited yet. Never injected.
    @ObservationIgnored
    private var processIdentifiersBeingRestarted: Set<pid_t> = []

    /// The channel the organizer edits the Dock's layout through, or why there is none to use.
    ///
    /// Only a payload of this app's build answers the layout requests, and only one whose hooks went in
    /// has a layout library running. There is one Dock per login session, so the first payload is it.
    func layoutChannelLookup() -> LayoutChannelLookup {
        guard let payload = residentPayloads.first else {
            return .unavailable(injectedProcessIdentifiers.isEmpty ? .notInjected : .payloadNotAnswering)
        }
        if payload.isStale {
            return .unavailable(.stalePayload)
        }
        guard payload.areHooksInstalled else {
            return .unavailable(.hooksNotInstalled)
        }
        guard let channel = channelsByHostProcessIdentifier[payload.hostProcessIdentifier] else {
            return .unavailable(.payloadNotAnswering)
        }
        return .available(channel)
    }

    // MARK: - The icon on the Dock's Apps tile

    /// What the app last decided about the Apps tile's icon, handed to every payload as it connects.
    ///
    /// Held here rather than read by the payload out of a preference domain: the payload runs inside the
    /// Dock, and the app is the only side that knows both the preference and where its own bundle is. Not
    /// observed — the control panel reads the switch from ``DockAppsIconController``, not from here.
    @ObservationIgnored
    private var dockAppsIconRequest: DockAppsIconRequest?

    /// Records the settings and hands them to every payload that can be reached right now.
    ///
    /// Returns what those payloads answered, so the control panel can say when a Dock has no hook on its
    /// icon path. A payload that cannot be reached is left out rather than reported as a failure: it is
    /// told as soon as it connects, from ``sendDockAppsIconSettings(to:)``.
    @discardableResult
    public func applyDockAppsIcon(isEnabled: Bool, iconBundlePath: String) async -> [DockAppsIconReply] {
        dockAppsIconRequest = DockAppsIconRequest(isEnabled: isEnabled, iconBundlePath: iconBundlePath)
        // A snapshot: the dictionary can change while this awaits each payload in turn.
        let channels = Array(channelsByHostProcessIdentifier.values)
        var replies: [DockAppsIconReply] = []
        for channel in channels {
            do {
                replies.append(try await channel.setDockAppsIcon(isEnabled: isEnabled, iconBundlePath: iconBundlePath))
            } catch {
                #log(.error, "A payload would not change the Apps tile: \(error.localizedDescription, privacy: .public)")
            }
        }
        return replies
    }

    /// Tells one payload that just connected what the app has decided, if it has decided anything yet.
    ///
    /// Nothing to send is the normal state for the first moments of a launch, before
    /// ``DockAppsIconController`` has read the preference; its first call covers the payloads already
    /// connected by then.
    private func sendDockAppsIconSettings(to channel: PayloadChannel) async {
        guard let dockAppsIconRequest else { return }
        do {
            _ = try await channel.setDockAppsIcon(
                isEnabled: dockAppsIconRequest.isEnabled,
                iconBundlePath: dockAppsIconRequest.iconBundlePath
            )
        } catch {
            #log(.error, "A payload would not take the Apps tile settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Every payload this app can currently reach, sorted by host.
    ///
    /// Populated by injecting and by ``reconnectToResidentPayloads()``, and kept current by
    /// ``refreshState()``. This — not ``injectedProcessIdentifiers`` — is what makes the window honest
    /// across an app restart: these come from payloads that answered.
    public var residentPayloads: [ResidentPayload] {
        payloadStatusesByHostProcessIdentifier
            .values
            .map { status in
                ResidentPayload(
                    hostProcessIdentifier: status.hostProcessIdentifier,
                    hostProcessName: status.hostProcessName,
                    imageUUID: status.payloadImageUUID,
                    isStale: Self.isStale(imageUUID: status.payloadImageUUID, bundledImageUUIDs: bundledPayloadImageUUIDs),
                    hookState: ResidentPayload.HookState(status.hookInstallation),
                    dockBundleVersion: status.dockBuild.bundleVersion,
                    dockSystemRelease: status.dockBuild.systemRelease,
                    dockGlobalsReachability: .init(status.dockGlobalsReachability)
                )
            }
            .sorted { $0.hostProcessIdentifier < $1.hostProcessIdentifier }
    }

    /// Whether any Dock is running a payload other than the one in this app's bundle.
    ///
    /// A payload cannot be unloaded, so re-injecting a rebuilt one changes nothing — the only way out
    /// is restarting the Dock. Saying so beats letting someone re-inject repeatedly and conclude
    /// their change did not work.
    public var hasStalePayload: Bool {
        residentPayloads.contains { $0.isStale }
    }

    /// A resident payload is stale when its image is none of the bundled payload's slices.
    ///
    /// When the bundled payload cannot be read there is nothing to compare against, and claiming
    /// every payload is stale would send the user restarting the Dock for no reason.
    nonisolated static func isStale(imageUUID: UUID, bundledImageUUIDs: Set<UUID>) -> Bool {
        guard !bundledImageUUIDs.isEmpty else { return false }
        return !bundledImageUUIDs.contains(imageUUID)
    }

    /// UUIDs of every slice of the payload in this app's bundle, read once.
    @ObservationIgnored
    private lazy var bundledPayloadImageUUIDs: Set<UUID> = {
        guard let bundledPayloadURL = Self.bundledPayloadFrameworkURL else { return [] }
        let executableURL = bundledPayloadURL
            .appendingPathComponent("Versions/A/\(InjectionServiceIdentity.payloadFrameworkName)", isDirectory: false)
        return MachOFileUUIDReader.uuids(ofFileAt: executableURL)
    }()

    private var payloadStatusesByHostProcessIdentifier: [pid_t: PayloadStatus] = [:]

    private let daemonController: PrivilegedDaemonController
    private let injectionMethod: InjectionMethod
    private let processMonitor: TargetProcessMonitor

    @ObservationIgnored
    private var channelsByHostProcessIdentifier: [pid_t: PayloadChannel] = [:]

    /// When each channel was opened.
    ///
    /// A freshly injected payload takes a moment to finish its side of the handshake, and until it
    /// does, asking it for status fails exactly the way a payload that has died would. Giving up at
    /// that point closes this app's listener — the endpoint the payload is in the middle of
    /// connecting to — so the channel would be lost for the life of the Dock.
    @ObservationIgnored
    private var channelOpenedAtByHostProcessIdentifier: [pid_t: Date] = [:]

    /// How long a payload gets to complete its handshake before its channel is given up on.
    private static let payloadHandshakeGracePeriod: TimeInterval = 30

    @ObservationIgnored
    private var registry: InjectedPayloadRegistry { InjectedPayloadRegistry(daemonController: daemonController) }

    public init(
        daemonController: PrivilegedDaemonController,
        targetMatchingRule: TargetProcessMonitor.MatchingRule,
        injectionMethod: InjectionMethod = .dynamicLibraryLoad
    ) {
        self.daemonController = daemonController
        self.injectionMethod = injectionMethod
        self.processMonitor = TargetProcessMonitor(matchingRule: targetMatchingRule)
        self.isAutomaticInjectionEnabled = Self.loadAutomaticInjectionPreference()

        processMonitor.onProcessStarted = { [weak self] processIdentifier in
            Task { @MainActor in
                await self?.injectIntoNewlyDiscoveredTarget(processIdentifier)
            }
        }
        processMonitor.onProcessExited = { [weak self] processIdentifier in
            Task { @MainActor in
                self?.hostDidExit(processIdentifier)
            }
        }
        processMonitor.onDiscoveryPass = { [weak self] processIdentifiers in
            Task { @MainActor in
                await self?.injectIntoAnyMissedTargets(processIdentifiers)
            }
        }
    }

    // MARK: - Reconnecting to payloads that are already resident

    /// Finds payloads still running from an earlier session and reopens a channel to each.
    ///
    /// Call this on launch. Without it the app knows only what it injected during the current run,
    /// so a relaunch reports "not injected" while the payload is right there — and the obvious
    /// response, injecting again, does nothing, because a mapped image cannot be loaded twice.
    ///
    /// The daemon's registry only lists live processes: it watches each one and drops the entry on
    /// exit, so nothing here has to tell a live endpoint from a dead one.
    ///
    /// Also run by the first injection attempt that finds it has not happened yet, so that nothing
    /// injects a Dock before the registry has been asked whether it already holds the payload. The
    /// process monitor starts before the launch sequence and sees the Dock at once; on the test Mac
    /// it injected the resident Dock a hundred milliseconds after the reconnection, replacing the
    /// working channel with one the payload — whose peer starts only once — would never answer.
    public func reconnectToResidentPayloads() async {
        await residentPayloadReconnection.run { [self] in
            await readRegistryAndReconnect()
        }
    }

    @ObservationIgnored
    private let residentPayloadReconnection = SingleFlight<Void>()

    /// Whether the registry has been read since launch. Reading it only fails when the daemon is
    /// unusable, and then the next injection attempt — which makes the daemon usable first — tries
    /// again.
    @ObservationIgnored
    private var hasReadRegistry = false

    private func readRegistryAndReconnect() async {
        let endpoints: [InjectedEndpointInfo]
        do {
            endpoints = try await registry.liveEndpoints()
            hasReadRegistry = true
        } catch {
            #log(.error, "Could not read the injected-payload registry: \(error.localizedDescription, privacy: .public)")
            return
        }

        for endpointInfo in endpoints where channelsByHostProcessIdentifier[endpointInfo.pid] == nil {
            // Only the payload publishes an entry, and the daemon drops it when the Dock exits: an entry
            // means the payload is in this Dock, whether or not it answers below. Leaving the Dock off
            // the record would have the next discovery pass inject it again.
            injectedProcessIdentifiers.insert(endpointInfo.pid)

            var channel: PayloadChannel?
            do {
                let reconnectedChannel = try await PayloadChannel.reconnect(to: endpointInfo)
                channel = reconnectedChannel
                let status = try await reconnectedChannel.fetchStatus()

                channelsByHostProcessIdentifier[endpointInfo.pid] = reconnectedChannel
                channelOpenedAtByHostProcessIdentifier[endpointInfo.pid] = Date()
                payloadStatusesByHostProcessIdentifier[endpointInfo.pid] = status

                #log(.info, "Reconnected to the payload in \(status.hostProcessName, privacy: .public) (\(endpointInfo.pid, privacy: .public))")
                await sendDockAppsIconSettings(to: reconnectedChannel)
            } catch {
                // The payload is there but will not talk. Drop the registry entry rather than
                // retrying it on every launch from here on.
                await channel?.close()
                #log(.error, "Payload in \(endpointInfo.pid, privacy: .public) did not answer: \(error.localizedDescription, privacy: .public)")
                await registry.forget(hostProcessIdentifier: endpointInfo.pid)
            }
        }
    }

    /// Accounts for a host that has exited, then drops everything known about it.
    ///
    /// The one place an exit is counted towards the quick-exit guard, whichever noticed it first —
    /// the monitor's exit source or ``refreshState()``.
    private func hostDidExit(_ hostProcessIdentifier: pid_t) {
        let reachedLimit = quickExitGuard.recordExit(of: hostProcessIdentifier, at: Date())
        forgetHost(hostProcessIdentifier)
        processIdentifiersBeingRestarted.remove(hostProcessIdentifier)

        guard reachedLimit, isAutomaticInjectionEnabled else { return }
        setAutomaticInjectionEnabled(false)
        lastErrorDescription = "The Dock quit within \(Int(quickExitGuard.quickExitInterval)) seconds of being injected \(quickExitGuard.limit) times in a row, so automatic injection is now off. Fix the payload, then switch it back on."
        #log(.error, "Automatic injection switched off after \(self.quickExitGuard.limit, privacy: .public) quick exits in a row")
    }

    /// Drops everything known about a host, without counting it as an exit.
    private func forgetHost(_ hostProcessIdentifier: pid_t) {
        injectedProcessIdentifiers.remove(hostProcessIdentifier)
        quickExitGuard.forget(hostProcessIdentifier)
        dropPayloadChannel(for: hostProcessIdentifier)
    }

    /// Drops the channel to a payload and what it last reported, leaving the injection on record.
    ///
    /// Separate from ``forgetHost(_:)`` because conflating the two produced an injection loop in
    /// DockIconOverride. A payload that will not answer is not evidence that its host has gone, nor
    /// that the injection did not happen — the payload is a mapped image that cannot be unloaded, so
    /// "injected" stays true whether or not its side channel works. Removing the host from
    /// ``injectedProcessIdentifiers`` on a failed status request made the next discovery pass class
    /// it as never injected and inject it again, every few seconds, forever.
    private func dropPayloadChannel(for hostProcessIdentifier: pid_t) {
        payloadStatusesByHostProcessIdentifier.removeValue(forKey: hostProcessIdentifier)
        channelOpenedAtByHostProcessIdentifier.removeValue(forKey: hostProcessIdentifier)
        if let channel = channelsByHostProcessIdentifier.removeValue(forKey: hostProcessIdentifier) {
            Task { await channel.close() }
        }
    }

    /// Whether this host's channel is new enough that its payload could still be mid-handshake.
    private func isWithinHandshakeGracePeriod(_ hostProcessIdentifier: pid_t) -> Bool {
        guard let openedAt = channelOpenedAtByHostProcessIdentifier[hostProcessIdentifier] else { return false }
        return Date().timeIntervalSince(openedAt) < Self.payloadHandshakeGracePeriod
    }

    // MARK: - Keeping displayed state true

    /// Re-checks everything the window displays about hosts and payloads.
    ///
    /// State written when something happened and never revisited leaves a restarted Dock described
    /// by its predecessor: a dead process identifier under "Injected", a payload row from minutes
    /// ago, an outcome about a process that has since exited. The process monitor cleans some of it
    /// up, but only while it runs — and with automatic injection off it does not.
    ///
    /// Deliberately does not inject. Discovering that a target is uninjected is the monitor's job;
    /// this only makes what is shown match what is true.
    public func refreshState() async {
        for hostProcessIdentifier in knownHostProcessIdentifiers {
            let hostIsAlive = ProcessLiveness.isAlive(hostProcessIdentifier)
            let payloadHasEverAnswered = payloadStatusesByHostProcessIdentifier[hostProcessIdentifier] != nil

            // Only worth asking a live host, and only one with a channel to ask down.
            var payloadAnswered = true
            if hostIsAlive, let channel = channelsByHostProcessIdentifier[hostProcessIdentifier] {
                do {
                    let status = try await channel.fetchStatus()
                    // The Dock may have been forgotten while the request was out — Restart Dock does
                    // that — and writing the answer back would bring its row back for one more tick.
                    guard channelsByHostProcessIdentifier[hostProcessIdentifier] === channel else { continue }
                    payloadStatusesByHostProcessIdentifier[hostProcessIdentifier] = status
                } catch {
                    payloadAnswered = false
                }
            }

            let decision = HostRefreshDecision.decide(
                hostIsAlive: hostIsAlive,
                payloadAnswered: payloadAnswered,
                payloadHasEverAnswered: payloadHasEverAnswered,
                isWithinHandshakeGracePeriod: isWithinHandshakeGracePeriod(hostProcessIdentifier)
            )

            switch decision {
            case .keepAsIs, .waitForHandshake:
                continue
            case .dropChannelKeepingInjectionOnRecord:
                // Still injected — the image is in the process and cannot be unloaded. Only the
                // channel and whatever it last said are being given up.
                #log(.info, "Payload in \(hostProcessIdentifier, privacy: .public) will not answer; keeping the host on record as injected")
                dropPayloadChannel(for: hostProcessIdentifier)
            case .forgetEntirely:
                #log(.info, "Host \(hostProcessIdentifier, privacy: .public) is gone; dropping what was known about it")
                hostDidExit(hostProcessIdentifier)
            }
        }

        expireInjectionReportIfItsProcessesAreGone()
    }

    /// Everything this coordinator believes it knows something about.
    private var knownHostProcessIdentifiers: Set<pid_t> {
        injectedProcessIdentifiers
            .union(payloadStatusesByHostProcessIdentifier.keys)
            .union(channelsByHostProcessIdentifier.keys)
    }

    /// Drops the last outcome once every process it talks about has exited.
    ///
    /// A failure is kept: it describes something that went wrong rather than something that was true
    /// about a process, and it stays until the next attempt replaces it.
    private func expireInjectionReportIfItsProcessesAreGone() {
        guard let report = lastInjectionReport, !report.isFailure else { return }
        let describedProcessIdentifiers = report.outcome.processIdentifiers
        guard !describedProcessIdentifiers.isEmpty else { return }
        guard describedProcessIdentifiers.allSatisfy({ !ProcessLiveness.isAlive($0) }) else { return }

        lastInjectionReport = nil
    }

    // MARK: - Restarting the Dock

    /// Restarts every running target and injects into its replacement.
    ///
    /// All three steps belong to the one button. Forgetting the outgoing Docks has to happen here
    /// rather than being left to the exit sources, which only fire while the monitor runs; and
    /// injecting has to happen here for the same reason, or the button quietly depends on a
    /// preference that has nothing to do with what it says it does.
    ///
    /// `SIGTERM` is what `killall` sends; launchd starts a new Dock as soon as the old one exits.
    public func restartTargets() {
        let outgoingProcessIdentifiers = currentTargetProcessIdentifiers()
        prepareForTargetRestart()
        // Kept out of every injection until they exit. Forgotten a line above, they would otherwise
        // look uninjected to a discovery pass that saw them a moment ago.
        processIdentifiersBeingRestarted = outgoingProcessIdentifiers
        // Before the first suspension point, so the buttons are disabled from this frame on.
        isWaitingForTargetRestart = true

        for processIdentifier in outgoingProcessIdentifiers {
            switch ProcessTermination.terminate(processIdentifier) {
            case .terminated, .alreadyGone:
                continue
            case .belongsToAnotherUser:
                // Another user's Dock under fast user switching. It stays in the outgoing set all the
                // same, so it is never mistaken for this user's replacement Dock.
                #log(.info, "Left \(processIdentifier, privacy: .public) alone: it belongs to another user")
            case .failed(let reason):
                lastErrorDescription = "Could not restart the Dock (\(processIdentifier)): \(reason)"
                #log(.error, "Could not terminate \(processIdentifier, privacy: .public): \(reason, privacy: .public)")
            }
        }

        Task {
            await injectIntoNextTargetGeneration(replacing: outgoingProcessIdentifiers)
        }
    }

    /// Forgets every host, for when the targets are about to be replaced.
    ///
    /// Waiting for the exit sources to notice would leave the window describing the outgoing Dock
    /// for as long as that took. Forgetting also keeps those exits out of the quick-exit count.
    public func prepareForTargetRestart() {
        for hostProcessIdentifier in knownHostProcessIdentifiers {
            forgetHost(hostProcessIdentifier)
        }
        lastInjectionReport = nil
        lastErrorDescription = nil
        // Let the next discovery pass inject immediately instead of waiting out a previous failure's
        // backoff — the user just asked for this restart and is watching for the result.
        automaticRetryCooldown.reset()
    }

    /// Every target running right now. For recording what a restart is about to replace.
    public func currentTargetProcessIdentifiers() -> Set<pid_t> {
        Set(processMonitor.currentlyRunningTargetProcessIdentifiers())
    }

    /// Waits for targets to come back after a deliberate restart, then injects into them.
    ///
    /// Waiting for a process identifier that was *not* there before is what makes this correct
    /// rather than merely likely: polling for "any target" would find the outgoing Dock still
    /// winding down and inject into a process about to exit.
    public func injectIntoNextTargetGeneration(
        replacing outgoingProcessIdentifiers: Set<pid_t>,
        timeout: Duration = .seconds(20)
    ) async {
        isWaitingForTargetRestart = true
        defer {
            isWaitingForTargetRestart = false
            // Whatever has exited by now no longer needs keeping out; one that somehow outlived the
            // wait stays excluded until its exit is seen.
            processIdentifiersBeingRestarted = processIdentifiersBeingRestarted.filter(ProcessLiveness.isAlive)
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            let replacementProcessIdentifiers = currentTargetProcessIdentifiers()
                .subtracting(outgoingProcessIdentifiers)

            if !replacementProcessIdentifiers.isEmpty {
                await performInjection(
                    intoProcessIdentifiers: Array(replacementProcessIdentifiers),
                    trigger: .userRequested
                )
                return
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        record(outcome: .failed(description: "The Dock did not come back after being restarted."), trigger: .userRequested)
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

    private static var bundledPayloadFrameworkURL: URL? {
        Bundle.main.url(forResource: InjectionServiceIdentity.payloadFrameworkName, withExtension: "framework")
    }

    /// Copies the payload framework out of the app bundle into the root-owned staging directory.
    ///
    /// Re-running this replaces whatever is there, which is what you want after a rebuild — the
    /// staged copy is a snapshot, not a link, so a stale one would keep being injected forever.
    public func stagePayload() async throws {
        guard let bundledPayloadURL = Self.bundledPayloadFrameworkURL else {
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
            #log(.info, "Staged payload at \(destinationFrameworkURL.path, privacy: .public)")
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    /// This run's staging of its own payload, shared by every injection that needs it.
    ///
    /// A staged copy left by an earlier build still exists on disk, so `isPayloadStaged` alone would
    /// keep injecting that old build after every rebuild. Sharing one task also keeps two injections
    /// that start together — the launch-time one and the process monitor's — from staging at once,
    /// one deleting the framework while the other is loading it.
    @ObservationIgnored
    private var payloadStagingTask: Task<Void, any Error>?

    private func stagePayloadOncePerRun() async throws {
        if let payloadStagingTask {
            // This run's staging, finished or still under way. Reused while its copy is on disk; a
            // failed or since-deleted staging is done again below.
            if (try? await payloadStagingTask.value) != nil, isPayloadStaged {
                return
            }
        }
        let newStagingTask = Task { try await self.stagePayload() }
        payloadStagingTask = newStagingTask
        do {
            try await newStagingTask.value
        } catch {
            payloadStagingTask = nil
            throw error
        }
    }

    // MARK: - Injection

    /// Injects into every target running right now that has not been injected yet.
    ///
    /// Targets are found by scanning the process table rather than by reading what
    /// ``TargetProcessMonitor`` has discovered, because the monitor only discovers anything while
    /// automatic injection is on — consulting it here would make the button do nothing, silently,
    /// whenever the switch is off.
    @discardableResult
    public func injectIntoRunningTargets() async -> InjectionOutcome {
        await performInjection(
            intoProcessIdentifiers: processMonitor.currentlyRunningTargetProcessIdentifiers(),
            trigger: .userRequested
        )
    }

    /// Injects into a target the monitor has just seen for the first time.
    private func injectIntoNewlyDiscoveredTarget(_ processIdentifier: pid_t) async {
        guard isAutomaticInjectionEnabled else { return }
        await performInjection(intoProcessIdentifiers: [processIdentifier], trigger: .automatic)
    }

    /// Injects into targets that are running but were never successfully injected.
    ///
    /// Fed by every discovery pass, not just the pass that first sees a process. A target the app
    /// failed to inject is already being tracked by the monitor, so `onProcessStarted` never fires
    /// for it again — without this, one failed attempt left that Dock uninjected for its whole life,
    /// however long ago the reason for the failure had been fixed.
    private func injectIntoAnyMissedTargets(_ processIdentifiers: [pid_t]) async {
        guard isAutomaticInjectionEnabled else { return }

        let missedProcessIdentifiers = InjectionSelection.processIdentifiersNeedingInjection(
            running: processIdentifiers,
            alreadyInjected: injectedProcessIdentifiers,
            beingInjected: processIdentifiersBeingInjected,
            beingRestarted: processIdentifiersBeingRestarted
        )
        guard !missedProcessIdentifiers.isEmpty else { return }

        guard automaticRetryCooldown.permitsAttempt(at: Date()) else { return }

        await performInjection(intoProcessIdentifiers: missedProcessIdentifiers, trigger: .automatic)
    }

    /// The one path every injection takes, whoever asked for it.
    ///
    /// Making the daemon usable is part of injecting, not a precondition the caller has to have
    /// arranged. Every route into this — the button, a target appearing, a retry — needs the same
    /// thing, and leaving it to the callers meant that a first attempt after a boot, against a daemon
    /// whose launchd job had never started, failed identically every time until the user reinstalled
    /// the daemon by hand. Cheap when nothing is wrong — one round trip to compare versions — and
    /// rate-limited by the daemon controller's own cooldown when something is.
    @discardableResult
    private func performInjection(
        intoProcessIdentifiers processIdentifiers: [pid_t],
        trigger: InjectionTrigger
    ) async -> InjectionOutcome {
        guard !processIdentifiers.isEmpty else {
            return record(outcome: .noTargetRunning, trigger: trigger)
        }

        let availability = await daemonController.ensureDaemonUsable()
        guard availability.isUsable else {
            return record(outcome: .failed(description: availability.summary), trigger: trigger)
        }

        // Before deciding what is uninjected: a Dock already holding the payload from an earlier
        // session is only known once the registry has been read.
        if !hasReadRegistry {
            await reconnectToResidentPayloads()
        }

        // With the monitor off nothing reports a restarted Dock's exit, so a stale entry would keep
        // a later process that reused its identifier from ever being injected.
        processIdentifiersBeingRestarted = processIdentifiersBeingRestarted.filter(ProcessLiveness.isAlive)

        var newlyInjectedProcessIdentifiers: [pid_t] = []
        var previouslyInjectedProcessIdentifiers: [pid_t] = []
        var failureDescriptions: [String] = []

        for processIdentifier in processIdentifiers.sorted() {
            guard !injectedProcessIdentifiers.contains(processIdentifier) else {
                previouslyInjectedProcessIdentifiers.append(processIdentifier)
                continue
            }
            // Someone else is already on this one. Not a failure and not "already injected" — the
            // other attempt owns reporting it. A Dock being restarted is about to exit.
            guard
                !processIdentifiersBeingInjected.contains(processIdentifier),
                !processIdentifiersBeingRestarted.contains(processIdentifier)
            else { continue }

            // Claimed here rather than inside `inject` so that the test above and this write are in
            // the same synchronous run: calling an `async` function is itself a suspension point.
            processIdentifiersBeingInjected.insert(processIdentifier)
            do {
                try await inject(intoProcessIdentifier: processIdentifier)
                newlyInjectedProcessIdentifiers.append(processIdentifier)
            } catch {
                failureDescriptions.append(error.localizedDescription)
            }
            processIdentifiersBeingInjected.remove(processIdentifier)
        }

        if !failureDescriptions.isEmpty {
            return record(outcome: .failed(description: failureDescriptions.joined(separator: "\n")), trigger: trigger)
        }
        if !newlyInjectedProcessIdentifiers.isEmpty {
            return record(outcome: .injected(processIdentifiers: newlyInjectedProcessIdentifiers), trigger: trigger)
        }
        if !previouslyInjectedProcessIdentifiers.isEmpty {
            return record(outcome: .alreadyInjected(processIdentifiers: previouslyInjectedProcessIdentifiers), trigger: trigger)
        }
        // Everything in the batch was already being handled elsewhere. Nothing to report.
        return lastInjectionReport?.outcome ?? .noTargetRunning
    }

    /// Stages the payload if needed and injects it into one process. Throws so callers can report.
    ///
    /// Only called from ``performInjection(intoProcessIdentifiers:trigger:)``, which has already
    /// claimed this process identifier in ``processIdentifiersBeingInjected`` and releases it after.
    private func inject(intoProcessIdentifier processIdentifier: pid_t) async throws {
        try await stagePayloadOncePerRun()

        // Open the app's half of the channel first. The payload looks this endpoint up by the host's
        // process identifier the moment it starts, so registering after injecting would be a race
        // the payload usually loses — and it would then run with no channel for the life of the
        // Dock. A channel that cannot be opened is not fatal: injection is the point.
        let channel = try? await PayloadChannel.prepare(forHostProcessIdentifier: processIdentifier)
        if channel == nil {
            #log(.error, "Could not open a channel for \(processIdentifier, privacy: .public); injecting anyway")
        }

        let payloadURL = stagedPayloadExecutableURL
        do {
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
        } catch {
            // Each failed attempt would otherwise leave another listener registered under this
            // Dock's process identifier, and the automatic retry makes one every 15 seconds.
            await channel?.close()
            throw error
        }

        injectedProcessIdentifiers.insert(processIdentifier)
        quickExitGuard.recordInjection(of: processIdentifier, at: Date())
        lastErrorDescription = nil
        #log(.info, "Injected into \(processIdentifier, privacy: .public)")
        onInjectionSucceeded?()

        guard let channel else { return }
        // A channel already on record answered the payload's one handshake; the payload will never
        // connect to this one.
        guard channelsByHostProcessIdentifier[processIdentifier] == nil else {
            await channel.close()
            return
        }
        channelsByHostProcessIdentifier[processIdentifier] = channel
        channelOpenedAtByHostProcessIdentifier[processIdentifier] = Date()
        await adoptStatus(from: channel, hostProcessIdentifier: processIdentifier)
    }

    /// Waits for the freshly injected payload to call home, then records what it reports.
    ///
    /// Not part of injection succeeding. The payload is in the Dock either way; failing to reach it
    /// means the window has less to say, not that anything needs undoing.
    private func adoptStatus(from channel: PayloadChannel, hostProcessIdentifier: pid_t) async {
        guard await channel.waitUntilConnected() else {
            #log(.error, "Payload in \(hostProcessIdentifier, privacy: .public) did not open its channel")
            return
        }
        do {
            payloadStatusesByHostProcessIdentifier[hostProcessIdentifier] = try await channel.fetchStatus()
        } catch {
            #log(.error, "Payload in \(hostProcessIdentifier, privacy: .public) did not report status: \(error.localizedDescription, privacy: .public)")
        }
        await sendDockAppsIconSettings(to: channel)
    }

    @discardableResult
    private func record(outcome: InjectionOutcome, trigger: InjectionTrigger) -> InjectionOutcome {
        let report = InjectionReport(outcome: outcome, trigger: trigger)
        lastInjectionReport = report
        lastErrorDescription = outcome.isFailure ? outcome.summary : nil

        if trigger == .automatic {
            if outcome.isFailure {
                _ = automaticRetryCooldown.recordAttempt(at: Date())
            } else {
                automaticRetryCooldown.reset()
            }
        }

        if outcome.isFailure {
            #log(.error, "Injection request: \(report.summary, privacy: .public)")
        } else {
            #log(.info, "Injection request: \(report.summary, privacy: .public)")
        }

        return outcome
    }

    // MARK: - Automatic re-injection

    private enum PreferenceKey {
        static let automaticInjectionEnabled = "AutomaticInjectionEnabled"
    }

    /// Records the preference and brings the monitor in line with it.
    public func setAutomaticInjectionEnabled(_ shouldInjectAutomatically: Bool) {
        if shouldInjectAutomatically, !isAutomaticInjectionEnabled {
            quickExitGuard.reset()
        }
        isAutomaticInjectionEnabled = shouldInjectAutomatically
        UserDefaults.standard.set(shouldInjectAutomatically, forKey: PreferenceKey.automaticInjectionEnabled)
        synchronizeMonitoringWithPreference()
    }

    /// Starts the monitor if the stored preference asks for it.
    ///
    /// Safe to call before the daemon is known to work, and meant to be: the monitor only reads the
    /// process table, and starting it early is what gives a launch that could not reach the daemon a
    /// way back — every injection it attempts makes the daemon usable first.
    public func activateAutomaticInjectionIfEnabled() {
        synchronizeMonitoringWithPreference()
    }

    private func synchronizeMonitoringWithPreference() {
        guard isAutomaticInjectionEnabled != isMonitoringTargets else { return }
        isMonitoringTargets = isAutomaticInjectionEnabled

        if isMonitoringTargets {
            processMonitor.start()
        } else {
            processMonitor.stop()
        }
    }

    /// Defaults to on when nothing has been stored yet.
    ///
    /// Read through `object(forKey:)` rather than `bool(forKey:)` on purpose: the latter collapses
    /// "never set" and "set to false" into the same answer, which makes an on-by-default preference
    /// impossible to express.
    private static func loadAutomaticInjectionPreference() -> Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.automaticInjectionEnabled) as? Bool ?? true
    }
}

extension PayloadInjectionCoordinator.ResidentPayload.GlobalsReachability {
    init(_ reachability: DockGlobalsReachability) {
        switch reachability {
        case .reachable:
            self = .reachable
        case .unreachable(let missingClassNames):
            self = .unreachable(missingClassNames: missingClassNames)
        }
    }
}

extension PayloadInjectionCoordinator.ResidentPayload.HookState {
    init(_ hookInstallation: HookInstallation) {
        switch hookInstallation {
        case .installed(let hookCount):
            self = .installed(hookCount: hookCount)
        case .incompatibleDockMethods:
            self = .incompatibleDockMethods
        case .failed(let description):
            self = .failed(description: description)
        }
    }
}
