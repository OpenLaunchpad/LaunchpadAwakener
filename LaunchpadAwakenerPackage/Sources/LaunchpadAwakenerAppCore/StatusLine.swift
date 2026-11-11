import Darwin
import ServiceManagement

/// One status row of the control panel: its text, the colour of the dot beside it, and its help tag.
///
/// The dot carries the state at a glance; the text spells it out for anyone who cannot rely on the
/// colour, which is why a row always has both.
public struct StatusLine: Equatable, Sendable {
    public let text: String
    public let tint: StatusTint
    /// Details for the help tag; empty when there are none.
    public let help: String

    public init(text: String, tint: StatusTint, help: String = "") {
        self.text = text
        self.tint = tint
        self.help = help
    }
}

extension StatusLine {
    /// The Dock row: which macOS this Dock is running on, and whether the replica is working in it.
    ///
    /// `payload` is the first Dock that answered. There is one Dock per login session, so in practice
    /// it is the only one.
    ///
    /// There is no "unsupported build" any more — the payload finds what it needs by looking rather
    /// than by matching the build against a list — so what can go wrong here is narrower: the methods
    /// it replaces may have changed, or the globals it reads may be out of reach.
    public static func dockBuild(reportedBy payload: PayloadInjectionCoordinator.ResidentPayload?) -> StatusLine {
        guard let payload else {
            return StatusLine(
                text: "Known once the Dock is injected",
                tint: .neutral,
                help: "The payload reports which Dock it is in once it is injected."
            )
        }
        let release = "macOS \(payload.dockSystemRelease)"
        let text: String
        switch payload.hookState {
        case .installed where payload.areHooksInstalled && payload.areDockGlobalsReachable:
            text = "\(release) · supported"
        case .installed where payload.areHooksInstalled:
            text = "\(release) · Launchpad's entry points are missing"
        case .installed:
            text = "No hooks declared"
        case .incompatibleDockMethods:
            text = "Methods do not match"
        case .failed:
            text = "Hooks failed to install"
        }
        var helpLines = ["Dock \(payload.dockBundleVersion)", "Running on \(release)"]
        if case .unreachable(let missingClassNames) = payload.dockGlobalsReachability {
            helpLines.append("Not found in this Dock: \(missingClassNames.joined(separator: ", "))")
        }
        if case .failed(let description) = payload.hookState {
            helpLines.append(description)
        }
        let isWorking = payload.areHooksInstalled && payload.areDockGlobalsReachable
        return StatusLine(text: text, tint: isWorking ? .positive : .critical, help: helpLines.joined(separator: "\n"))
    }

    /// The Dock row of the injection section: which process, and what its payload says about itself.
    public static func injection(
        injectedProcessIdentifiers: Set<pid_t>,
        residentPayloads: [PayloadInjectionCoordinator.ResidentPayload]
    ) -> StatusLine {
        let help = residentPayloads
            .map { "\($0.hostProcessName) \($0.hostProcessIdentifier): payload image \($0.imageUUID.uuidString)" }
            .joined(separator: "\n")
        guard let processIdentifier = injectedProcessIdentifiers.min() else {
            return StatusLine(text: "Not injected", tint: .caution, help: help)
        }
        guard let payload = residentPayloads.first(where: { $0.hostProcessIdentifier == processIdentifier }) else {
            // Injected, but the payload has not answered — still connecting, or its channel dropped.
            return StatusLine(text: "Injected · process \(processIdentifier)", tint: .positive, help: help)
        }
        let buildDescription = payload.isStale ? "older build" : "current build"
        guard case .installed(let hookCount) = payload.hookState, hookCount > 0 else {
            return StatusLine(text: "Process \(processIdentifier) · \(buildDescription) · no hooks", tint: .critical, help: help)
        }
        return StatusLine(
            text: "Process \(processIdentifier) · \(buildDescription) · \(hookCount) hook\(hookCount == 1 ? "" : "s")",
            tint: payload.isStale ? .caution : .positive,
            help: help
        )
    }
}

extension StatusLine {
    /// The input method helper row: its LaunchAgent's registration until that is enabled, then which copy
    /// of the helper runs.
    public static func textInputHelper(registrationStatus: SMAppService.Status, helperState: TextInputHelperState) -> StatusLine {
        let registrationTint = StatusTint(registrationStatus)
        switch registrationStatus {
        case .enabled:
            break
        case .notRegistered:
            return StatusLine(text: "Not registered — search and rename fields work without input methods.", tint: registrationTint)
        case .requiresApproval:
            return StatusLine(text: "Turned off under System Settings › Login Items.", tint: registrationTint)
        case .notFound:
            return StatusLine(text: "Not found — the helper is missing from the app bundle.", tint: registrationTint)
        @unknown default:
            return StatusLine(text: "Unknown status (\(registrationStatus.rawValue)).", tint: registrationTint)
        }
        switch helperState {
        case .notRunning:
            return StatusLine(
                text: "Registered — starts when Launchpad opens.",
                tint: .positive,
                help: "launchd starts the helper the first time Launchpad opens, and it stays up until you log out."
            )
        case .current(let process):
            return StatusLine(text: "Running · process \(process.processIdentifier)", tint: .positive, help: process.executablePath)
        case .replacedSinceLaunch(let process):
            return StatusLine(
                text: "An older build is running · process \(process.processIdentifier)",
                tint: .caution,
                help: "The helper was rebuilt or reinstalled after it started, so it still runs the old code. Restart it: the next time Launchpad opens, launchd starts the new one."
            )
        case .otherCopy(let process):
            return StatusLine(
                text: "Another copy is running · process \(process.processIdentifier)",
                tint: .caution,
                help: "It runs from \(process.executablePath). Restart it to run this app's copy the next time Launchpad opens, unless the other copy registers the helper again."
            )
        }
    }
}
