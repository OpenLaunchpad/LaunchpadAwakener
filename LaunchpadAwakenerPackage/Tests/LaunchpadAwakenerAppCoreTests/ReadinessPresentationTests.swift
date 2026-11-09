import Testing
@testable import LaunchpadAwakenerAppCore

/// How each readiness reads in the banner, and which one-click step the banner offers with it.
@Suite("Readiness presentation")
struct ReadinessPresentationTests {
    struct Expectation: Sendable, CustomTestStringConvertible {
        let readiness: ControlPanelReadiness
        let title: String
        let symbolName: String
        let tint: StatusTint
        let action: ReadinessAction?

        var testDescription: String { title }
    }

    static let expectations: [Expectation] = [
        Expectation(readiness: .startingUp(progressDescription: "Checking the privileged daemon…"), title: "Starting up", symbolName: "hourglass.circle.fill", tint: .progress, action: nil),
        Expectation(readiness: .awaitingDaemonApproval, title: "Waiting for approval", symbolName: "hand.raised.circle.fill", tint: .caution, action: .openLoginItems),
        Expectation(readiness: .daemonMissingFromBundle, title: "Daemon missing from the app bundle", symbolName: "exclamationmark.triangle.fill", tint: .critical, action: nil),
        Expectation(readiness: .daemonNotInstalled, title: "Not installed", symbolName: "circle.dashed", tint: .neutral, action: .installDaemon),
        Expectation(readiness: .killSwitchEngaged, title: "Paused", symbolName: "pause.circle.fill", tint: .paused, action: .turnLaunchpadBackOn),
        Expectation(readiness: .startupStopped(reason: "The daemon is registered but unreachable."), title: "Startup did not finish", symbolName: "exclamationmark.triangle.fill", tint: .caution, action: .injectNow),
        Expectation(readiness: .notInjected, title: "Not injected", symbolName: "bolt.horizontal.circle.fill", tint: .caution, action: .injectNow),
        Expectation(readiness: .hooksNotInstalled(.unknownDockBuild(executableUUID: "0F1E")), title: "This Dock build is not supported", symbolName: "xmark.octagon.fill", tint: .critical, action: nil),
        Expectation(readiness: .stalePayload, title: "Restart the Dock to update", symbolName: "clock.badge.exclamationmark.fill", tint: .caution, action: .restartDock),
        Expectation(readiness: .active, title: "Active", symbolName: "checkmark.circle.fill", tint: .positive, action: nil),
    ]

    @Test("each readiness has its title, symbol, tint and next step", arguments: expectations)
    func presentation(of expectation: Expectation) {
        let presentation = ReadinessPresentation(expectation.readiness)
        #expect(presentation.title == expectation.title)
        #expect(presentation.symbolName == expectation.symbolName)
        #expect(presentation.tint == expectation.tint)
        #expect(presentation.action == expectation.action)
    }

    @Test("a launch in progress or one that stopped says what it is doing in its own words")
    func progressAndReasonAreShownAsGiven() {
        #expect(ReadinessPresentation(.startingUp(progressDescription: "Checking the privileged daemon…")).nextStep == "Checking the privileged daemon…")
        #expect(ReadinessPresentation(.startupStopped(reason: "The daemon is registered but unreachable.")).nextStep == "The daemon is registered but unreachable.")
    }

    @Test("hooks that did not install say why the Dock keeps opening the system's Apps", arguments: [
        (PayloadInjectionCoordinator.ResidentPayload.HookState.incompatibleDockMethods, "This Dock does not match its build profile", "The Dock keeps opening the system's Apps: the methods the payload calls have different signatures."),
        (.failed(description: "Tile has no setter"), "The payload's hooks did not install", "The Dock keeps opening the system's Apps: one of them failed validation, so none were installed."),
        (.installed(hookCount: 0), "The payload has no hooks", "The Dock keeps opening the system's Apps: this build of the payload declares none."),
    ])
    func hooksNotInstalled(hookState: PayloadInjectionCoordinator.ResidentPayload.HookState, title: String, nextStep: String) {
        let presentation = ReadinessPresentation(.hooksNotInstalled(hookState))
        #expect(presentation.title == title)
        #expect(presentation.nextStep == nextStep)
    }

    @Test("the banner's buttons are named for the step they take")
    func actionTitles() {
        #expect(ReadinessAction.installDaemon.title == "Install")
        #expect(ReadinessAction.openLoginItems.title == "Open Login Items")
        #expect(ReadinessAction.turnLaunchpadBackOn.title == "Turn Back On")
        #expect(ReadinessAction.injectNow.title == "Inject Now")
        #expect(ReadinessAction.restartDock.title == "Restart Dock")
    }
}
