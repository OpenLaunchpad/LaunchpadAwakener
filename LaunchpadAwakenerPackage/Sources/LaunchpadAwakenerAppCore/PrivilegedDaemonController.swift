import Foundation
import AppKit
import ServiceManagement
import OSLog
import HelperClient
import HelperCommunication
import LaunchpadAwakenerShared

/// Owns the privileged daemon's lifecycle and the single XPC connection to it.
///
/// One instance, one connection. Every request the app sends to the daemon goes through
/// ``send(request:)`` so there is never more than one channel open, and so connection
/// re-establishment has exactly one place to live.
@Observable
@MainActor
public final class PrivilegedDaemonController {
    private static let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakener", category: "PrivilegedDaemonController")

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

    @ObservationIgnored
    private var activationObservationTask: Task<Void, Never>?

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
        statusMessage = Self.describe(status: registrationStatus)
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
            Self.logger.error("Daemon registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func uninstall() async {
        isPerformingRegistrationChange = true
        defer {
            isPerformingRegistrationChange = false
            refreshStatus()
        }

        invalidateConnection()
        do {
            try await installer.unregister()
        } catch {
            statusMessage = Self.describe(registrationError: error as NSError)
            Self.logger.error("Daemon unregistration failed: \(error.localizedDescription, privacy: .public)")
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

    /// Sends a request to the daemon, connecting first if needed.
    @discardableResult
    public func send<DaemonRequest: HelperCommunication.Request>(request: DaemonRequest) async throws -> DaemonRequest.Response {
        try await ensureConnected()
        return try await helperClient.sendToTool(request: request)
    }

    // MARK: - Version reconciliation

    public enum VersionCheckOutcome {
        case upToDate
        /// The daemon was stale and has been reinstalled. Its new build is now resident.
        case reinstalled
        /// The daemon is stale but not enabled, so it cannot be reinstalled without the user acting.
        case staleButNotEnabled
        /// The version query failed for a reason that does not imply staleness. Nothing was changed.
        case queryFailed(any Error)
        /// Unregistering succeeded but re-registering did not. The daemon may be in a mixed state.
        case reinstallFailed(any Error)
    }

    /// Compares the resident daemon's version against this build's and reinstalls on mismatch.
    ///
    /// Call this on launch. Without it, the single most common development-time confusion is an old
    /// daemon binary still resident after a rebuild, answering requests with last week's behaviour.
    ///
    /// Only an "unrecognised message" error is read as staleness — every other error (connection
    /// refused, interrupted, plain XPC failure) is transient and must not trigger a reinstall, or a
    /// momentary hiccup would tear down a perfectly good daemon.
    public func reconcileVersion() async -> VersionCheckOutcome {
        let residentVersion: String?
        do {
            try await ensureConnected()
            residentVersion = try await helperClient.fetchToolVersion()
        } catch {
            guard HelperClient.errorIndicatesOutdatedPeer(error) else {
                Self.logger.error("Version query failed, treating as transient: \(error.localizedDescription, privacy: .public)")
                return .queryFailed(error)
            }
            residentVersion = nil
        }

        if let residentVersion, residentVersion == InjectionServiceIdentity.daemonVersion {
            return .upToDate
        }

        Self.logger.info(
            "Daemon is stale — resident: \(residentVersion ?? "unknown", privacy: .public), expected: \(InjectionServiceIdentity.daemonVersion, privacy: .public)"
        )

        guard Self.daemon.status == .enabled else { return .staleButNotEnabled }

        invalidateConnection()
        do {
            try await installer.unregister()
        } catch {
            // Keep going: register() below may still succeed from a not-registered state.
            Self.logger.error("Unregister during reinstall failed: \(error.localizedDescription, privacy: .public)")
        }

        // SMAppService's on-disk bookkeeping lags behind the unregister await; registering
        // immediately fails intermittently with "already registered" without this pause.
        try? await Task.sleep(for: .seconds(1))

        do {
            try await installer.register()
        } catch {
            refreshStatus()
            return .reinstallFailed(error)
        }

        refreshStatus()
        return .reinstalled
    }

    // MARK: - Messages

    private static func describe(status: SMAppService.Status) -> String {
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
