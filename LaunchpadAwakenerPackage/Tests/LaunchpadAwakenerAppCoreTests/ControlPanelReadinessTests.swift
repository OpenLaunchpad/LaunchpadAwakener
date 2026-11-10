import Foundation
import ServiceManagement
import Testing
@testable import LaunchpadAwakenerAppCore

/// Covers what the window's banner says first. Each case only applies once everything before it is
/// fine, so these tests pin the order: the banner must name the first obstacle, not a later symptom.
@Suite("Control panel readiness")
struct ControlPanelReadinessTests {
    private typealias ResidentPayload = PayloadInjectionCoordinator.ResidentPayload

    private static func payload(
        hookState: ResidentPayload.HookState = .installed(hookCount: 2),
        isStale: Bool = false
    ) -> ResidentPayload {
        ResidentPayload(
            hostProcessIdentifier: 512,
            hostProcessName: "Dock",
            imageUUID: UUID(),
            isStale: isStale,
            hookState: hookState,
            dockBundleVersion: "1985.6.3",
            dockSystemReleases: ["27.2 (26B123)"]
        )
    }

    private static func evaluate(
        isInjectionBlockedBySystemIntegrityProtection: Bool = false,
        isStandaloneLaunchpadInstalled: Bool = false,
        launchPhase: ApplicationLaunchProgress.Phase = .ready,
        daemonStatus: SMAppService.Status = .enabled,
        isKillSwitchEngaged: Bool = false,
        isInjected: Bool = true,
        residentPayloads: [ResidentPayload] = [payload()]
    ) -> ControlPanelReadiness {
        ControlPanelReadiness.evaluate(
            isInjectionBlockedBySystemIntegrityProtection: isInjectionBlockedBySystemIntegrityProtection,
            isStandaloneLaunchpadInstalled: isStandaloneLaunchpadInstalled,
            launchPhase: launchPhase,
            daemonStatus: daemonStatus,
            isKillSwitchEngaged: isKillSwitchEngaged,
            isInjected: isInjected,
            residentPayloads: residentPayloads
        )
    }

    @Test("Everything in place is active")
    func everythingInPlaceIsActive() {
        #expect(Self.evaluate() == .active)
    }

    /// While SIP is on nothing below can be fixed by injecting, so the banner points at the standalone app
    /// whatever else is going on — the launch sequence does not even run then.
    @Test("SIP on is reported before anything else, with the standalone app's state")
    func systemIntegrityProtectionComesFirst() {
        #expect(
            Self.evaluate(isInjectionBlockedBySystemIntegrityProtection: true, launchPhase: .notStarted, daemonStatus: .notRegistered, isInjected: false, residentPayloads: [])
                == .systemIntegrityProtectionEnabled(isStandaloneLaunchpadInstalled: false)
        )
        #expect(
            Self.evaluate(isInjectionBlockedBySystemIntegrityProtection: true, isStandaloneLaunchpadInstalled: true, launchPhase: .preparingDaemon, isKillSwitchEngaged: true)
                == .systemIntegrityProtectionEnabled(isStandaloneLaunchpadInstalled: true)
        )
    }

    @Test("With SIP off, the standalone app being installed changes nothing")
    func standaloneApplicationIgnoredWithoutSystemIntegrityProtection() {
        #expect(Self.evaluate(isStandaloneLaunchpadInstalled: true) == .active)
    }

    @Test("A launch still running is reported before anything else")
    func launchInProgressComesFirst() {
        #expect(
            Self.evaluate(launchPhase: .preparingDaemon, daemonStatus: .notRegistered, isInjected: false)
                == .startingUp(progressDescription: "Checking the privileged daemon…")
        )
    }

    @Test("The daemon's registration decides the next step", arguments: [
        (SMAppService.Status.requiresApproval, ControlPanelReadiness.awaitingDaemonApproval),
        (.notFound, .daemonMissingFromBundle),
        (.notRegistered, .daemonNotInstalled),
    ])
    func daemonStatusDecides(daemonStatus: SMAppService.Status, expected: ControlPanelReadiness) {
        #expect(Self.evaluate(daemonStatus: daemonStatus, isKillSwitchEngaged: true, isInjected: false) == expected)
    }

    /// With the switch on, nothing else changes what the Dock does; turning it off is the step the
    /// user is most likely looking for.
    @Test("The kill switch outranks injection state")
    func killSwitchOutranksInjection() {
        #expect(Self.evaluate(isKillSwitchEngaged: true, isInjected: false) == .killSwitchEngaged)
        #expect(Self.evaluate(isKillSwitchEngaged: true) == .killSwitchEngaged)
    }

    @Test("A launch that stopped explains why nothing is injected")
    func stoppedLaunchExplainsNotInjected() {
        #expect(
            Self.evaluate(launchPhase: .stopped(reason: "The daemon is registered but unreachable."), isInjected: false)
                == .startupStopped(reason: "The daemon is registered but unreachable.")
        )
        #expect(Self.evaluate(isInjected: false, residentPayloads: []) == .notInjected)
    }

    /// The reason this app's banner has a case DockIconOverride's does not: on a Dock build without a
    /// profile the payload goes in, installs nothing, and the Dock looks exactly as if nothing had
    /// happened. Saying "Active" there would be the worst possible answer.
    @Test("A payload with no hooks is not active", arguments: [
        PayloadInjectionCoordinator.ResidentPayload.HookState.unknownDockBuild(executableUUID: "0F0E"),
        .incompatibleDockMethods,
        .failed(description: "signature mismatch"),
        .installed(hookCount: 0),
    ])
    func payloadWithoutHooksIsNotActive(hookState: PayloadInjectionCoordinator.ResidentPayload.HookState) {
        #expect(Self.evaluate(residentPayloads: [Self.payload(hookState: hookState)]) == .hooksNotInstalled(hookState))
    }

    /// A stale payload with no hooks is reported as having no hooks: restarting the Dock would load
    /// the new build, which on an unknown Dock build installs nothing either.
    @Test("Missing hooks outrank a stale payload")
    func missingHooksOutrankStaleness() {
        let inertStalePayload = Self.payload(hookState: .incompatibleDockMethods, isStale: true)
        #expect(Self.evaluate(residentPayloads: [inertStalePayload]) == .hooksNotInstalled(.incompatibleDockMethods))
    }

    @Test("A stale payload asks for a Dock restart")
    func stalePayloadAsksForRestart() {
        #expect(Self.evaluate(residentPayloads: [Self.payload(isStale: true)]) == .stalePayload)
    }

    /// Injected but not heard from — a payload still connecting, or one whose channel was dropped.
    /// The injection happened and cannot be undone, so there is nothing to fix.
    @Test("An injected Dock whose payload has not answered counts as active")
    func silentInjectedDockIsActive() {
        #expect(Self.evaluate(residentPayloads: []) == .active)
    }
}

/// Covers the one-time default that turns launching at login on.
@Suite("Launch at login default")
struct LaunchAtLoginDefaultTests {
    @Test("Nothing decided yet registers")
    func undecidedRegisters() {
        #expect(LaunchAtLoginDefault.decide(hasAppliedDefault: false, status: .notRegistered) == .register)
    }

    /// A build from before the toggle registered the item on every launch; that state is kept as is.
    @Test("An item already registered is left alone")
    func alreadyRegisteredIsLeftAlone() {
        #expect(LaunchAtLoginDefault.decide(hasAppliedDefault: false, status: .enabled) == .recordWithoutRegistering)
    }

    /// Turned off in System Settings is a decision the app cannot override, and should not try to.
    @Test("An item switched off in System Settings is left alone")
    func switchedOffInSettingsIsLeftAlone() {
        #expect(LaunchAtLoginDefault.decide(hasAppliedDefault: false, status: .requiresApproval) == .recordWithoutRegistering)
    }

    /// The regression the toggle guards against: launching at login used to be forced on whenever
    /// automatic injection started, so a user who turned it off found it back on next launch.
    @Test("Once applied, the user's choice stands", arguments: [
        SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound,
    ])
    func appliedDefaultIsNotReapplied(status: SMAppService.Status) {
        #expect(LaunchAtLoginDefault.decide(hasAppliedDefault: true, status: status) == .alreadyApplied)
    }
}

/// Covers the kill switch as the window's toggle. Uses a file of its own, never the real one: the
/// real one changes what this Mac's Dock does.
@Suite("Kill switch")
@MainActor
struct KillSwitchControllerTests {
    private let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchpadAwakenerKillSwitchTests-\(UUID().uuidString)")
        .path

    @Test("Engaging creates the file and releasing removes it")
    func engagingAndReleasing() {
        defer { try? FileManager.default.removeItem(atPath: path) }
        let controller = KillSwitchController(path: path)
        #expect(!controller.isEngaged)

        controller.setEngaged(true)
        #expect(controller.isEngaged)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(controller.lastErrorDescription == nil)

        controller.setEngaged(false)
        #expect(!controller.isEngaged)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// The file is also created from a terminal — the way out when the screen is unusable — so the
    /// toggle has to follow the file, not its own memory.
    @Test("A file created elsewhere shows on the next refresh")
    func refreshFollowsTheFile() throws {
        defer { try? FileManager.default.removeItem(atPath: path) }
        let controller = KillSwitchController(path: path)

        try Data().write(to: URL(fileURLWithPath: path))
        controller.refreshStatus()
        #expect(controller.isEngaged)
    }

    @Test("Asking for the state it is already in succeeds without touching the file")
    func redundantChangeSucceeds() {
        let controller = KillSwitchController(path: path)
        controller.setEngaged(false)
        #expect(!controller.isEngaged)
        #expect(controller.lastErrorDescription == nil)
    }

    @Test("A path that cannot be written reports why")
    func unwritablePathReportsError() {
        let controller = KillSwitchController(path: "/nonexistent-directory/LaunchpadAwakener.disabled")
        controller.setEngaged(true)
        #expect(!controller.isEngaged)
        #expect(controller.lastErrorDescription != nil)
    }
}
