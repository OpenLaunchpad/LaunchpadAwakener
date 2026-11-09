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
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "TextInputAgentController")
@Observable
@MainActor
public final class TextInputAgentController {
    public private(set) var registrationStatus: SMAppService.Status = .notRegistered

    /// Human-readable explanation of ``registrationStatus``, suitable for direct display.
    public private(set) var statusMessage: String = "Checking…"

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
        statusMessage = Self.describe(status: registrationStatus)
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

    private static func describe(status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:
            return "Not registered — search and rename fields work without input methods."
        case .enabled:
            return "Registered."
        case .requiresApproval:
            return "Turned off under System Settings › Login Items."
        case .notFound:
            return "Not found — the helper is missing from the app bundle."
        @unknown default:
            return "Unknown status (\(status.rawValue))."
        }
    }
}
