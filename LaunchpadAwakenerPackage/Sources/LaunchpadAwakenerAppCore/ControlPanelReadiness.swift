import Foundation
import ServiceManagement

/// The one thing the window says first: is Launchpad replacing Apps in the Dock right now, and if
/// not, what stands in the way.
///
/// The window's sections each report their own piece, which leaves the reader to assemble "so is
/// anything actually happening?" from several rows. This states it outright. The cases are checked
/// in order, and each one only applies once everything before it is fine — the first obstacle is the
/// one worth fixing first.
public enum ControlPanelReadiness: Sendable, Equatable {
    /// System Integrity Protection is on, so nothing can be injected into the Dock. The standalone
    /// Launchpad works without turning it off; whether it is installed decides the next step.
    case systemIntegrityProtectionEnabled(isStandaloneLaunchpadInstalled: Bool)
    /// The launch sequence is still running; the description says which step.
    case startingUp(progressDescription: String)
    /// The daemon is registered and waits for the user under System Settings › Login Items.
    case awaitingDaemonApproval
    /// The build did not embed the daemon.
    case daemonMissingFromBundle
    case daemonNotInstalled
    /// The user switched Launchpad off; every entry opens the system's Apps.
    case killSwitchEngaged
    /// The launch stopped before injecting, for this reason.
    case startupStopped(reason: String)
    /// The daemon is ready but no Dock holds the payload.
    case notInjected
    /// A payload answered and installed no hooks, so the Dock keeps opening the system's Apps.
    case hooksNotInstalled(PayloadInjectionCoordinator.ResidentPayload.HookState)
    /// A Dock holds a payload other than this app's build. Only restarting it replaces the payload.
    case stalePayload
    case active

    public static func evaluate(
        isInjectionBlockedBySystemIntegrityProtection: Bool,
        isStandaloneLaunchpadInstalled: Bool,
        launchPhase: ApplicationLaunchProgress.Phase,
        daemonStatus: SMAppService.Status,
        isKillSwitchEngaged: Bool,
        isInjected: Bool,
        residentPayloads: [PayloadInjectionCoordinator.ResidentPayload]
    ) -> ControlPanelReadiness {
        // Before everything else: while SIP is on, no step below can be taken, and the app does not try.
        if isInjectionBlockedBySystemIntegrityProtection {
            return .systemIntegrityProtectionEnabled(isStandaloneLaunchpadInstalled: isStandaloneLaunchpadInstalled)
        }

        if launchPhase.isInProgress {
            return .startingUp(progressDescription: launchPhase.progressDescription ?? "")
        }

        switch daemonStatus {
        case .enabled:
            break
        case .requiresApproval:
            return .awaitingDaemonApproval
        case .notFound:
            return .daemonMissingFromBundle
        default:
            return .daemonNotInstalled
        }

        // Before injection: with the switch on nothing else changes what the Dock does, and turning
        // it off is the step the user is most likely looking for.
        if isKillSwitchEngaged {
            return .killSwitchEngaged
        }

        guard isInjected else {
            // A launch that stopped early is the more useful thing to say: "not injected" is the
            // symptom, and the reason the launch gave is the cause.
            if case .stopped(let reason) = launchPhase {
                return .startupStopped(reason: reason)
            }
            return .notInjected
        }

        if let inertPayload = residentPayloads.first(where: { !$0.areHooksInstalled }) {
            return .hooksNotInstalled(inertPayload.hookState)
        }

        if residentPayloads.contains(where: \.isStale) {
            return .stalePayload
        }

        return .active
    }
}
