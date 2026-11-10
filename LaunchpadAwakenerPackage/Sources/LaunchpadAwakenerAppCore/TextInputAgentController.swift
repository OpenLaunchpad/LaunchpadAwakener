import Foundation
import AppKit
import LaunchpadAwakenerShared
import OSToolbox
import ServiceManagement

/// The LaunchAgent that hosts the springboard's text fields so that input methods work in them.
///
/// launchd starts it when the payload in the Dock connects to its Mach service; until it is
/// registered, the springboard edits its fields itself, without input methods. Like the login item,
/// its status is read back from `SMAppService` rather than remembered: the user can switch it off in
/// System Settings, and nothing tells the app.
///
/// Once started, the helper stays up until the user logs out, so a new build or installation of the app
/// leaves the old helper running; reinstalling the daemon does not touch it. ``helperState`` says which
/// copy runs, ``restartHelper()`` ends it so that launchd starts this app's copy the next time Launchpad
/// opens, and ``restartHelperIfReplaced()`` does that by itself at launch.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "TextInputAgentController")
@Observable
@MainActor
public final class TextInputAgentController {
    public private(set) var registrationStatus: SMAppService.Status = .notRegistered

    /// Which copy of the helper is running, read from the process table.
    public private(set) var helperState: TextInputHelperState = .notRunning

    /// What the control panel's row says: the registration until the agent is enabled, then the helper.
    public var statusLine: StatusLine {
        .textInputHelper(registrationStatus: registrationStatus, helperState: helperState)
    }

    /// Whether there is a helper process to restart.
    public var canRestartHelper: Bool {
        helperState.process != nil
    }

    /// Most recent failure, cleared on the next successful registration. For display.
    public private(set) var lastErrorDescription: String?

    public var isEnabled: Bool { registrationStatus == .enabled }

    /// Registered, then switched off under System Settings › Login Items. Only the user can undo that.
    public var isDisabledInSystemSettings: Bool { registrationStatus == .requiresApproval }

    @ObservationIgnored
    private var activationObservationTask: Task<Void, Never>?

    private static var service: SMAppService {
        SMAppService.agent(plistName: TextInputServiceIdentity.agentPropertyListName)
    }

    public init() {
        refreshStatus()
        activationObservationTask = Task { [weak self] in
            let activations = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
            for await _ in activations {
                guard let self else { return }
                self.refreshStatus()
            }
        }
    }

    deinit {
        activationObservationTask?.cancel()
    }

    public func refreshStatus() {
        registrationStatus = Self.service.status
        helperState = TextInputHelperState.now()
    }

    /// Ends the running helper with `SIGTERM`. launchd starts this app's copy the next time the payload
    /// connects, when Launchpad opens; the LaunchAgent keeps no process alive in between.
    public func restartHelper() {
        refreshStatus()
        guard let process = helperState.process else { return }
        switch ProcessTermination.terminate(process.processIdentifier) {
        case .terminated, .alreadyGone:
            lastErrorDescription = nil
            #log(.info, "Ended the input method helper, process \(process.processIdentifier, privacy: .public)")
        case .belongsToAnotherUser:
            #log(.error, "The input method helper, process \(process.processIdentifier, privacy: .public), belongs to another user")
        case .failed(let reason):
            lastErrorDescription = "Could not restart the input method helper: \(reason)"
            #log(.error, "Could not end the input method helper, process \(process.processIdentifier, privacy: .public): \(reason, privacy: .public)")
        }
        // The process is gone once launchd reaps it, a moment after the signal.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.refreshStatus()
        }
    }

    /// At launch: restarts the helper when this app's copy was rebuilt or reinstalled after it started, the
    /// way the daemon is reinstalled when its version does not match. A copy from elsewhere is only shown.
    public func restartHelperIfReplaced() {
        refreshStatus()
        guard helperState.isRestartedAutomatically else { return }
        #log(.info, "This build replaced the running input method helper; restarting it")
        restartHelper()
    }

    /// Registers the agent unless it already is; a user who switched it off in Login Items stays
    /// switched off.
    public func registerIfNeeded() {
        defer { refreshStatus() }
        let status = Self.service.status
        guard status == .notRegistered || status == .notFound else { return }
        do {
            try Self.service.register()
            lastErrorDescription = nil
            #log(.info, "Registered the text input agent")
        } catch {
            lastErrorDescription = "Could not register the input method helper: \(error.localizedDescription)"
            #log(.error, "Could not register the text input agent: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
