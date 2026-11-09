import Foundation
import AppKit
import ServiceManagement
import OSToolbox
import HelperClient
import HelperCommunication
import LaunchpadAwakenerShared

/// Owns the privileged daemon's lifecycle and the single XPC connection to it.
///
/// One instance, one connection. Every request the app sends to the daemon goes through
/// ``send(request:)`` so there is never more than one channel open, and so connection
/// re-establishment has exactly one place to live.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "PrivilegedDaemonController")
@Observable
@MainActor
public final class PrivilegedDaemonController {
    /// Registration status as reported by `SMAppService`.
    public private(set) var registrationStatus: SMAppService.Status = .notRegistered

    /// Human-readable explanation of ``registrationStatus``, suitable for direct display.
    public private(set) var statusMessage: String = "Checking…"

    /// True while an install or uninstall is in flight.
    public private(set) var isPerformingRegistrationChange: Bool = false

    public var isEnabled: Bool { registrationStatus == .enabled }

    @ObservationIgnored
    private let helperClient = HelperClient()

    @ObservationIgnored
    private let installer = SMAppServiceDaemonInstaller(plistName: InjectionServiceIdentity.daemonPropertyListName)

    @ObservationIgnored
    private var hasConnected = false

    /// Keeps a genuinely broken daemon from being reinstalled on every request.
    ///
    /// See ``ensureDaemonUsable()`` and ``RepairCooldown`` for why a cooldown replaced the old
    /// "only reinstall on a version mismatch" rule.
    @ObservationIgnored
    private var reinstallCooldown = RepairCooldown(
        interval: PrivilegedDaemonController.reinstallCooldownInterval
    )

    @ObservationIgnored
    private var activationObservationTask: Task<Void, Never>?

    /// How long to wait after a reinstall attempt before trying another one.
    ///
    /// Long enough that a momentary XPC hiccup cannot cause repeated reinstalls, short enough that a
    /// user who is watching the window sees it recover rather than giving up on the tool.
    private static let reinstallCooldownInterval: TimeInterval = 60

    private static var daemon: SMAppService {
        SMAppService.daemon(plistName: InjectionServiceIdentity.daemonPropertyListName)
    }

    public init() {
        refreshStatus()
        observeApplicationActivation()
    }

    deinit {
        activationObservationTask?.cancel()
    }

    /// Re-reads the registration status every time the app comes back to the front.
    ///
    /// Approval happens in System Settings, in another process, and `SMAppService` publishes nothing
    /// when it lands. Without this the displayed status stays at whatever it was when the window was
    /// built, so the user approves the daemon, switches back, and is still told approval is pending.
    private func observeApplicationActivation() {
        activationObservationTask = Task { [weak self] in
            let activations = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
            for await _ in activations {
                guard let self else { return }
                self.refreshStatus()
            }
        }
    }

    // MARK: - Registration

    public func refreshStatus() {
        registrationStatus = Self.daemon.status
        statusMessage = DaemonStatusDescription.of(registrationStatus)
    }

    /// Registers the daemon, prompting the user through System Settings when approval is required.
    ///
    /// `SMAppService.daemon` registration always needs the user to approve the item once, under
    /// System Settings › General › Login Items. There is no way to skip it, so the honest behaviour
    /// is to open that pane rather than fail with a message the user cannot act on.
    public func install() async {
        isPerformingRegistrationChange = true
        defer {
            isPerformingRegistrationChange = false
            refreshStatus()
        }

        switch Self.daemon.status {
        case .enabled:
            statusMessage = "Already installed and enabled."
            return
        case .requiresApproval:
            statusMessage = "Registered — approve it under System Settings › Login Items."
            SMAppService.openSystemSettingsLoginItems()
            return
        default:
            break
        }

        do {
            try await installer.register()
            if Self.daemon.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            statusMessage = Self.describe(registrationError: error as NSError)
            if (error as NSError).code == kSMErrorLaunchDeniedByUser || (error as NSError).code == 1 {
                SMAppService.openSystemSettingsLoginItems()
            }
            #log(.error, "Daemon registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func uninstall() async {
        isPerformingRegistrationChange = true
        defer {
            isPerformingRegistrationChange = false
            refreshStatus()
        }

        // A deliberate uninstall clears the automatic-repair cooldown: whatever it was waiting out
        // no longer describes the situation, and the next install should not be told to come back
        // in a minute because of it.
        reinstallCooldown.reset()
        invalidateConnection()
        do {
            try await installer.unregister()
        } catch {
            statusMessage = Self.describe(registrationError: error as NSError)
            #log(.error, "Daemon unregistration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Connection

    /// Opens the XPC connection if it is not already open. Idempotent.
    public func ensureConnected() async throws {
        guard !hasConnected else { return }
        try await helperClient.connectToTool(
            machServiceName: InjectionServiceIdentity.machServiceName,
            isPrivilegedHelperTool: true
        )
        hasConnected = true
    }

    public func invalidateConnection() {
        hasConnected = false
    }

    /// Sends a request to the daemon, reconnecting and retrying once if the connection has expired.
    ///
    /// The retry exists because ``hasConnected`` used to be a latch that only ever went up: once the
    /// first connection succeeded, a daemon that later exited, crashed or was reinstalled left this
    /// controller convinced it was still connected, and every subsequent request went down a dead
    /// channel forever. Nothing reset it short of relaunching the app.
    ///
    /// Whether to retry is decided by *asking the connection*, not by inspecting the thrown error.
    /// Matching on error codes would mean either importing `SwiftyXPC` — a transitive dependency of
    /// `HelperClient`, not one this module should link — or hardcoding a bridged `NSError` domain
    /// string and case numbering that no longer holds the moment that library is reorganised. A ping
    /// answers the only question that matters, in terms that cannot go stale: is this channel still
    /// carrying messages? If it is, the failure belongs to the request and is rethrown untouched.
    @discardableResult
    public func send<DaemonRequest: HelperCommunication.Request>(request: DaemonRequest) async throws -> DaemonRequest.Response {
        try await ensureConnected()
        do {
            return try await helperClient.sendToTool(request: request)
        } catch {
            guard await !helperClient.isConnectedToTool else { throw error }

            #log(.info, "Connection to the daemon has expired; reconnecting and retrying once")
            invalidateConnection()
            try await ensureConnected()
            return try await helperClient.sendToTool(request: request)
        }
    }

    // MARK: - Availability

    /// Whether the daemon can be used right now, and if not, what stands in the way.
    public enum DaemonAvailability: Sendable, Equatable {
        /// Reachable and running the version this build expects.
        case available
        /// Was unusable, has been reinstalled, and now answers.
        case recovered
        /// Unusable, and a reinstall was attempted too recently to try another.
        case unavailableCoolingDown(reason: String, retryAfter: Date)
        /// Unusable, and reinstalling did not fix it.
        case unrecoverable(reason: String)
        /// Not registered, or waiting for the user to approve it. No amount of retrying helps.
        case needsUserAction(SMAppService.Status)

        public var isUsable: Bool {
            switch self {
            case .available, .recovered:
                return true
            case .unavailableCoolingDown, .unrecoverable, .needsUserAction:
                return false
            }
        }

        /// One line suitable for display.
        public var summary: String {
            switch self {
            case .available:
                return "The daemon is ready."
            case .recovered:
                return "The daemon was not responding and has been reinstalled."
            case .unavailableCoolingDown(let reason, let retryAfter):
                let seconds = max(0, Int(retryAfter.timeIntervalSinceNow.rounded(.up)))
                return "\(reason) Reinstalling again in \(seconds)s."
            case .unrecoverable(let reason):
                return reason
            case .needsUserAction(let status):
                return DaemonStatusDescription.of(status)
            }
        }
    }

    /// Makes sure the daemon is usable, reinstalling it if it is not.
    ///
    /// Call this on launch and before anything that needs the daemon.
    ///
    /// ## Why "unreachable" reinstalls
    ///
    /// This replaced a version check that only reinstalled when the daemon *answered* with the wrong
    /// version, and treated every connection failure as a transient hiccup to be waited out. The
    /// reasoning was sound in isolation — a momentary XPC failure must not tear down a working
    /// daemon — but it made the one repair path unreachable in exactly the case that needs it. A
    /// launchd job whose `BundleProgram` no longer resolves does not come back on its own: it is not
    /// started at login despite `KeepAlive`, and a connection attempt does not launch it on demand
    /// either. Observed in DockIconOverride on 2026-08-11, where `launchctl` reported `runs = 1` for a job that had not
    /// started once between boot and being reinstalled by hand.
    ///
    /// The original concern is handled by ``reinstallCooldown`` instead. Deciding *whether* to
    /// repair by classifying the error meant a whole category of breakage had no route back;
    /// deciding *how often* to repair by the clock covers both cases with one rule.
    public func ensureDaemonUsable() async -> DaemonAvailability {
        refreshStatus()

        guard registrationStatus == .enabled else {
            return .needsUserAction(registrationStatus)
        }

        switch await diagnoseResidentDaemon() {
        case .usable:
            return .available
        case .needsReinstall(let reason):
            #log(.info, "Daemon needs reinstalling: \(reason, privacy: .public)")
            return await reinstall(because: reason)
        }
    }

    private enum ResidentDaemonDiagnosis {
        case usable
        case needsReinstall(reason: String)
    }

    private func diagnoseResidentDaemon() async -> ResidentDaemonDiagnosis {
        do {
            try await ensureConnected()
            let residentVersion = try await helperClient.fetchToolVersion()
            guard residentVersion == InjectionServiceIdentity.daemonVersion else {
                return .needsReinstall(
                    reason: "The running daemon is version \(residentVersion); this build expects \(InjectionServiceIdentity.daemonVersion)."
                )
            }
            return .usable
        } catch {
            // An "unrecognised message" answer is still an answer: the daemon is running, it simply
            // predates the version query. Everything else means it did not answer at all.
            if HelperClient.errorIndicatesOutdatedPeer(error) {
                return .needsReinstall(reason: "The running daemon predates this build's request set.")
            }
            return .needsReinstall(
                reason: "The daemon is registered but unreachable: \(error.localizedDescription)"
            )
        }
    }

    /// Unregisters and re-registers the daemon, then waits for the new one to answer.
    private func reinstall(because reason: String) async -> DaemonAvailability {
        let attemptTime = Date()
        guard reinstallCooldown.recordAttempt(at: attemptTime) else {
            let retryAfter = reinstallCooldown.nextPermittedAttempt(after: attemptTime) ?? attemptTime
            #log(.info, "Skipping reinstall; last attempt was less than \(Self.reinstallCooldownInterval, privacy: .public)s ago")
            return .unavailableCoolingDown(reason: reason, retryAfter: retryAfter)
        }

        isPerformingRegistrationChange = true
        defer {
            isPerformingRegistrationChange = false
            refreshStatus()
        }

        invalidateConnection()
        do {
            try await installer.unregister()
        } catch {
            // Keep going: register() below may still succeed from a not-registered state.
            #log(.error, "Unregister during reinstall failed: \(error.localizedDescription, privacy: .public)")
        }

        // SMAppService's on-disk bookkeeping lags behind the unregister await; registering
        // immediately fails intermittently with "already registered" without this pause.
        try? await Task.sleep(for: .seconds(1))

        do {
            try await installer.register()
        } catch {
            return .unrecoverable(reason: "Reinstalling the daemon failed: \(error.localizedDescription)")
        }

        refreshStatus()

        // Re-registering can land back in `requiresApproval`, which no amount of waiting resolves.
        // Saying so beats spending the timeout below on a daemon that is not going to start.
        guard registrationStatus == .enabled else {
            return .needsUserAction(registrationStatus)
        }

        guard await waitUntilDaemonAnswers() else {
            return .unrecoverable(reason: "The daemon was reinstalled but still does not answer.")
        }

        #log(.info, "Daemon reinstalled and answering")
        return .recovered
    }

    /// Polls until the daemon accepts a connection, or the timeout runs out.
    ///
    /// `register()` returning is not the same as the daemon being ready — launchd still has to spawn
    /// it and the process still has to publish its Mach service. Sending the next request the moment
    /// registration returns is a race, and losing it looks exactly like the failure this whole
    /// routine exists to repair.
    private func waitUntilDaemonAnswers(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var retryDelay = Duration.milliseconds(200)

        while ContinuousClock.now < deadline {
            invalidateConnection()
            do {
                try await ensureConnected()
                return true
            } catch {
                try? await Task.sleep(for: retryDelay)
                // Back off so a daemon that needs a few seconds is not hammered, but stay well
                // inside the timeout so a fast one is noticed promptly.
                retryDelay = min(retryDelay * 2, .seconds(2))
            }
        }

        return false
    }

    // MARK: - Messages

    private static func describe(registrationError: NSError) -> String {
        switch registrationError.code {
        case kSMErrorAlreadyRegistered:
            return "Already registered."
        case kSMErrorLaunchDeniedByUser:
            return "Denied — enable it under System Settings › Login Items."
        case kSMErrorInvalidSignature:
            return "Invalid signature. Check that the app and the daemon are signed by the same team."
        case 1:
            return "Approval required under System Settings › Login Items."
        default:
            return "Failed: \(registrationError.localizedDescription)"
        }
    }
}

/// Wording for `SMAppService.Status`, kept outside ``PrivilegedDaemonController``.
///
/// Both the controller and its nested ``PrivilegedDaemonController/DaemonAvailability`` need these
/// strings, and the latter is not main-actor isolated — a `static` member of the controller would
/// not be callable from it.
enum DaemonStatusDescription {
    static func of(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:
            return "Not installed."
        case .enabled:
            return "Installed and enabled."
        case .requiresApproval:
            return "Awaiting approval under System Settings › Login Items."
        case .notFound:
            return "Not found — the daemon is missing from the app bundle."
        @unknown default:
            return "Unknown status (\(status.rawValue))."
        }
    }
}
