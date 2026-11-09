/// How one ``ControlPanelReadiness`` reads: the control panel's banner, and the first line of the menu
/// bar menu.
public struct ReadinessPresentation: Equatable, Sendable {
    public let title: String
    /// What to do next, or what is going on.
    public let nextStep: String
    /// The banner's SF Symbol.
    public let symbolName: String
    public let tint: StatusTint
    /// The one-click next step, where there is one.
    public let action: ReadinessAction?

    public init(_ readiness: ControlPanelReadiness) {
        switch readiness {
        case .startingUp(let progressDescription):
            self.init(title: "Starting up", nextStep: progressDescription, symbolName: "hourglass.circle.fill", tint: .progress)
        case .awaitingDaemonApproval:
            self.init(
                title: "Waiting for approval",
                nextStep: "Approve “LaunchpadAwakener” under System Settings › General › Login Items.",
                symbolName: "hand.raised.circle.fill",
                tint: .caution,
                action: .openLoginItems
            )
        case .daemonMissingFromBundle:
            self.init(
                title: "Daemon missing from the app bundle",
                nextStep: "The build did not embed the daemon. Rebuild with ./RunScript.sh.",
                symbolName: "exclamationmark.triangle.fill",
                tint: .critical
            )
        case .daemonNotInstalled:
            self.init(
                title: "Not installed",
                nextStep: "Install the privileged daemon to get started.",
                symbolName: "circle.dashed",
                tint: .neutral,
                action: .installDaemon
            )
        case .killSwitchEngaged:
            self.init(
                title: "Paused",
                nextStep: "The Dock opens the system's Apps until Launchpad is turned back on.",
                symbolName: "pause.circle.fill",
                tint: .paused,
                action: .turnLaunchpadBackOn
            )
        case .startupStopped(let reason):
            self.init(title: "Startup did not finish", nextStep: reason, symbolName: "exclamationmark.triangle.fill", tint: .caution, action: .injectNow)
        case .notInjected:
            self.init(
                title: "Not injected",
                nextStep: "The daemon is ready. Inject into the Dock to replace Apps with Launchpad.",
                symbolName: "bolt.horizontal.circle.fill",
                tint: .caution,
                action: .injectNow
            )
        case .hooksNotInstalled(let hookState):
            let title: String
            let reason: String
            switch hookState {
            case .unknownDockBuild:
                title = "This Dock build is not supported"
                reason = "LaunchpadAwakener has no build profile for it"
            case .incompatibleDockMethods:
                title = "This Dock does not match its build profile"
                reason = "the methods the payload calls have different signatures"
            case .failed:
                title = "The payload's hooks did not install"
                reason = "one of them failed validation, so none were installed"
            case .installed:
                title = "The payload has no hooks"
                reason = "this build of the payload declares none"
            }
            self.init(title: title, nextStep: "The Dock keeps opening the system's Apps: \(reason).", symbolName: "xmark.octagon.fill", tint: .critical)
        case .stalePayload:
            self.init(
                title: "Restart the Dock to update",
                nextStep: "The Dock still runs an older build of the payload; re-injecting does not replace it.",
                symbolName: "clock.badge.exclamationmark.fill",
                tint: .caution,
                action: .restartDock
            )
        case .active:
            self.init(title: "Active", nextStep: "Launchpad replaces Apps in the Dock.", symbolName: "checkmark.circle.fill", tint: .positive)
        }
    }

    private init(title: String, nextStep: String, symbolName: String, tint: StatusTint, action: ReadinessAction? = nil) {
        self.title = title
        self.nextStep = nextStep
        self.symbolName = symbolName
        self.tint = tint
        self.action = action
    }
}

/// The step the banner's button takes.
public enum ReadinessAction: Sendable, Equatable {
    case installDaemon
    case openLoginItems
    case turnLaunchpadBackOn
    case injectNow
    case restartDock

    public var title: String {
        switch self {
        case .installDaemon: "Install"
        case .openLoginItems: "Open Login Items"
        case .turnLaunchpadBackOn: "Turn Back On"
        case .injectNow: "Inject Now"
        case .restartDock: "Restart Dock"
        }
    }
}
