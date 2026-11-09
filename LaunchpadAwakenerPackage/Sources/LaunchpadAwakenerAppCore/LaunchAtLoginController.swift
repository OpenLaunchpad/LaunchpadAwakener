import Foundation
import AppKit
import ServiceManagement
import OSToolbox

/// Owns whether the app is registered to launch at login.
///
/// The status is read back from `SMAppService` every time it is needed rather than mirrored into a
/// stored preference. The user can switch the login item off in System Settings at any moment and
/// nothing notifies the app when they do, so a remembered boolean starts lying from that point on —
/// the interface would show "on" while the app silently never launches again.
///
/// Registering the main app as a login item differs from registering the daemon in one way worth
/// knowing: it needs no prior approval. `SMAppService.daemon` lands in `requiresApproval` and stays
/// there until the user acts, which is why ``PrivilegedDaemonController/install()`` opens System
/// Settings. A login item registers straight to `enabled`; `requiresApproval` here means the
/// opposite — the user had it on and turned it off.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "LaunchAtLoginController")
@Observable
@MainActor
public final class LaunchAtLoginController {
    /// Registration status as reported by `SMAppService`.
    public private(set) var registrationStatus: SMAppService.Status = .notRegistered

    /// Human-readable explanation of ``registrationStatus``, suitable for direct display.
    public private(set) var statusMessage: String = "Checking…"

    /// Most recent failure, cleared on the next successful change. For display.
    public private(set) var lastErrorDescription: String?

    public var isEnabled: Bool { registrationStatus == .enabled }

    /// True when the login item is registered but the user switched it off in System Settings.
    ///
    /// Distinct from "never registered": the app cannot turn this back on by itself, so the only
    /// honest thing the interface can do is say so and offer to open the right pane.
    public var isDisabledInSystemSettings: Bool { registrationStatus == .requiresApproval }

    @ObservationIgnored
    private var activationObservationTask: Task<Void, Never>?

    @ObservationIgnored
    private let userDefaults: UserDefaults

    private static var loginItem: SMAppService { .mainApp }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        refreshStatus()
        observeApplicationActivation()
    }

    deinit {
        activationObservationTask?.cancel()
    }

    /// Re-reads the status every time the app comes back to the front.
    ///
    /// The Login Items pane in System Settings is another process and `SMAppService` publishes
    /// nothing when the user flips the switch there. Without this the toggle keeps showing whatever
    /// was true when the window was built.
    private func observeApplicationActivation() {
        activationObservationTask = Task { [weak self] in
            let activations = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
            for await _ in activations {
                guard let self else { return }
                self.refreshStatus()
            }
        }
    }

    public func refreshStatus() {
        registrationStatus = Self.loginItem.status
        statusMessage = Self.describe(status: registrationStatus)
    }

    /// Registers or unregisters the login item, and remembers that the user has decided.
    ///
    /// Synchronous because `SMAppService`'s login-item registration is: unlike the daemon, there is
    /// no approval round-trip to wait on.
    public func setEnabled(_ shouldLaunchAtLogin: Bool) {
        userDefaults.set(true, forKey: PreferenceKey.hasAppliedDefault)
        applyRegistration(shouldLaunchAtLogin)
    }

    /// Turns launching at login on the first time the tool has worked, unless that already happened
    /// or the user has decided for themselves.
    ///
    /// A Dock injected once and not after the next login is a tool that silently stops working, so
    /// the default is on. It is applied once rather than on every launch: before the switch had a
    /// toggle of its own it was forced on with every launch, and a user who turned it off would have
    /// found it back on the next time the app ran.
    public func applyDefaultIfNeeded() {
        let decision = LaunchAtLoginDefault.decide(
            hasAppliedDefault: userDefaults.bool(forKey: PreferenceKey.hasAppliedDefault),
            status: Self.loginItem.status
        )
        switch decision {
        case .alreadyApplied:
            return
        case .recordWithoutRegistering:
            userDefaults.set(true, forKey: PreferenceKey.hasAppliedDefault)
        case .register:
            userDefaults.set(true, forKey: PreferenceKey.hasAppliedDefault)
            applyRegistration(true)
            #log(.info, "Turned launch at login on by default")
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func applyRegistration(_ shouldLaunchAtLogin: Bool) {
        defer { refreshStatus() }

        // Once the user has switched the item off in System Settings, registering again does not
        // bring it back — the switch there is the authority. Sending them to it is the only route.
        if shouldLaunchAtLogin, isDisabledInSystemSettings {
            openLoginItemsSettings()
            return
        }

        do {
            if shouldLaunchAtLogin {
                try Self.loginItem.register()
                #log(.info, "Registered as a login item")
            } else {
                try Self.loginItem.unregister()
                #log(.info, "Unregistered as a login item")
            }
            lastErrorDescription = nil
        } catch {
            let registrationError = error as NSError
            // Both of these mean the item is already in the state being asked for, which is a
            // success as far as anyone calling this is concerned.
            if registrationError.code == kSMErrorAlreadyRegistered || registrationError.code == kSMErrorJobNotFound {
                lastErrorDescription = nil
                return
            }
            lastErrorDescription = Self.describe(registrationError: registrationError)
            #log(.error, "Login item change to \(shouldLaunchAtLogin, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private enum PreferenceKey {
        static let hasAppliedDefault = "launchAtLoginDefaultApplied"
    }

    // MARK: - Messages

    private static func describe(status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:
            return "Off."
        case .enabled:
            return "On — starts with your Mac."
        case .requiresApproval:
            return "Turned off under System Settings › Login Items."
        case .notFound:
            return "Not found — the app bundle could not be located."
        @unknown default:
            return "Unknown status (\(status.rawValue))."
        }
    }

    private static func describe(registrationError: NSError) -> String {
        switch registrationError.code {
        case kSMErrorInvalidSignature:
            return "Invalid signature. Apps using SMAppService must be code signed."
        case kSMErrorLaunchDeniedByUser:
            return "Denied — enable it under System Settings › Login Items."
        default:
            return "Failed: \(registrationError.localizedDescription)"
        }
    }
}

/// Whether to turn launching at login on by default, given what has happened so far.
enum LaunchAtLoginDefault: Equatable {
    /// The default was applied before, or the user chose. Their choice stands.
    case alreadyApplied
    /// The item is already registered — by hand, or by a build from before the toggle existed — or
    /// the user turned it off in System Settings. Remember that the default is settled, change nothing.
    case recordWithoutRegistering
    /// Nothing has decided yet. Register.
    case register

    static func decide(hasAppliedDefault: Bool, status: SMAppService.Status) -> LaunchAtLoginDefault {
        guard !hasAppliedDefault else { return .alreadyApplied }
        switch status {
        case .notRegistered, .notFound:
            return .register
        case .enabled, .requiresApproval:
            return .recordWithoutRegistering
        @unknown default:
            return .recordWithoutRegistering
        }
    }
}
