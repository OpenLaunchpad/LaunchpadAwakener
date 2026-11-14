import AppKit
import AppKitPlus
import LaunchpadAwakenerAppCore
import LaunchpadAwakenerSharedUI
import OSToolbox

/// The injected app: owns its controllers, its windows and menu bar item, and its launch sequence.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "ApplicationDelegate")
@MainActor
public final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let daemonController: PrivilegedDaemonController
    private let injectionCoordinator: PayloadInjectionCoordinator
    private let activationPolicyController = ApplicationActivationPolicyController()
    private let launchAtLoginController = LaunchAtLoginController()
    private let textInputAgentController = TextInputAgentController()
    private let killSwitchController = KillSwitchController()
    private let dockAppsIconController: DockAppsIconController
    private let standaloneLaunchpadController = StandaloneLaunchpadController()
    private let launchProgress = ApplicationLaunchProgress()
    private let organizerViewModel: LaunchpadOrganizerViewModel
    private var statusItemController: StatusItemController?

    /// Whether System Integrity Protection keeps this app from injecting into the Dock. Read once: changing
    /// SIP takes a restart.
    private let isInjectionBlockedBySystemIntegrityProtection = SystemIntegrityProtectionConfiguration.blocksInjection(
        active: SystemIntegrityProtectionConfiguration.active(),
        launchArguments: ProcessInfo.processInfo.arguments
    )

    private lazy var controlPanelWindowController = ControlPanelWindowController(
        controlPanelViewController: ControlPanelViewController(
            daemonController: daemonController,
            injectionCoordinator: injectionCoordinator,
            launchAtLoginController: launchAtLoginController,
            textInputAgentController: textInputAgentController,
            killSwitchController: killSwitchController,
            dockAppsIconController: dockAppsIconController,
            standaloneLaunchpadController: standaloneLaunchpadController,
            launchProgress: launchProgress,
            isInjectionBlockedBySystemIntegrityProtection: isInjectionBlockedBySystemIntegrityProtection,
            showOrganizer: { [weak self] in self?.showOrganizer() }
        ),
        activationPolicyController: activationPolicyController
    )

    private lazy var organizerWindowController = OrganizerWindowController(
        viewModel: organizerViewModel,
        injectionCoordinator: injectionCoordinator,
        activationPolicyController: activationPolicyController
    )

    override public init() {
        let daemonController = PrivilegedDaemonController()
        self.daemonController = daemonController
        let injectionCoordinator = PayloadInjectionCoordinator(
            daemonController: daemonController,
            // The Dock's executable path is fixed, so match on the full path rather than the name — an
            // unrelated process called "Dock" would otherwise be injected too.
            targetMatchingRule: .executablePath("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"),
            injectionMethod: .dynamicLibraryLoad
        )
        self.injectionCoordinator = injectionCoordinator
        self.dockAppsIconController = DockAppsIconController(injectionCoordinator: injectionCoordinator)
        self.organizerViewModel = LaunchpadOrganizerViewModel(organizer: LaunchpadOrganizer(injectionCoordinator: injectionCoordinator))
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Read first: the open event that tells a launch at login apart is only current until launching
        // finishes.
        let wasLaunchedAtLogin = ApplicationLaunch.wasLaunchedAtLogin

        // The organizer edits Launchpad through the payload in the Dock, which there is none of while SIP is on.
        let organizerItems = isInjectionBlockedBySystemIntegrityProtection ? [] : [
            menuItem("Organize Launchpad") { [weak self] in self?.showOrganizer() },
        ]
        NSApp.mainMenu = ApplicationMainMenu.make(applicationName: "LaunchpadAwakener", windowItems: [
            menuItem("LaunchpadAwakener") { [weak self] in self?.showControlPanel() },
        ] + organizerItems)
        statusItemController = StatusItemController(
            daemonController: daemonController,
            injectionCoordinator: injectionCoordinator,
            killSwitchController: killSwitchController,
            dockAppsIconController: dockAppsIconController,
            standaloneLaunchpadController: standaloneLaunchpadController,
            launchProgress: launchProgress,
            isInjectionBlockedBySystemIntegrityProtection: isInjectionBlockedBySystemIntegrityProtection,
            showControlPanel: { [weak self] in self?.showControlPanel() },
            showOrganizer: { [weak self] in self?.showOrganizer() }
        )

        // While SIP is on there is nothing to inject into: the daemon would only ask for approval in System
        // Settings, and the input method helper only serves Launchpad in the Dock. The window says so and
        // offers the standalone app instead, which needs none of them.
        guard !isInjectionBlockedBySystemIntegrityProtection else {
            #log(.info, "System Integrity Protection is on: offering the standalone Launchpad instead of injecting into the Dock")
            if !wasLaunchedAtLogin {
                showControlPanel()
            }
            return
        }

        // A Dock injected once and not after the next login is a tool that silently stops working, so the
        // first time the tool works, launching at login is turned on — once, and only if the user has not
        // decided for themselves.
        injectionCoordinator.onInjectionSucceeded = { [launchAtLoginController] in
            launchAtLoginController.applyDefaultIfNeeded()
        }

        // Before anything that can fail. The monitor needs no daemon and no privileges — it reads the
        // process table — and it is what retries injection for as long as the app runs. Starting it only
        // once the daemon had been confirmed usable would make the one mechanism that can recover from a
        // bad launch the one thing a bad launch never reaches.
        injectionCoordinator.activateAutomaticInjectionIfEnabled()

        // Needs no daemon either: launchd only starts the helper when a payload connects to it. A helper
        // left running from before this build was installed still runs the old code; it is ended, and launchd
        // starts this one the next time Launchpad opens.
        textInputAgentController.registerIfNeeded()
        textInputAgentController.restartHelperIfReplaced()

        // Only the launch at login keeps the window closed; the app then waits in the menu bar. Opened by
        // the user — from the Finder, the Dock, `open` — it shows the control panel whether or not
        // launching at login is on.
        #log(.info, "Launched \(wasLaunchedAtLogin ? "at login; the control panel stays closed" : "by the user; showing the control panel", privacy: .public)")
        if !wasLaunchedAtLogin {
            showControlPanel()
        }

        Task { await runLaunchSequence() }
    }

    /// Opening the app again while it runs brings the control panel back.
    ///
    /// With no Dock icon and no open window, opening the app from the Finder produces a reopen rather
    /// than a launch. Without this the menu bar item would be the only way back in — the state launching
    /// at login leaves the app in after every boot.
    public func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        showControlPanel()
        return false
    }

    /// Runs the launch sequence again when it stopped, each time the app comes to the front.
    ///
    /// A launch stops when the daemon is not usable — most often because it still waits for approval in
    /// System Settings. Coming back from there activates the app, and the sequence then gets as far as it
    /// now can. Without this the banner kept the old reason ("Awaiting approval") after the approval, and
    /// with automatic injection off nothing reconnected to a Dock that already held the payload.
    public func applicationDidBecomeActive(_ notification: Notification) {
        guard !isInjectionBlockedBySystemIntegrityProtection else {
            // Coming back from the Finder, where the user may have installed or deleted the standalone app.
            standaloneLaunchpadController.refreshStatus()
            return
        }
        guard case .stopped = launchProgress.phase else { return }
        // Entered here rather than inside the task, so that a second activation in the meantime sees a
        // sequence in progress and does not start another.
        launchProgress.enter(.preparingDaemon)
        Task { await runLaunchSequence() }
    }

    private func showControlPanel() {
        controlPanelWindowController.present()
    }

    private func showOrganizer() {
        organizerWindowController.present()
    }

    private func menuItem(_ title: String, perform action: @escaping () -> Void) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.primaryAction = NSAction { _ in
            action()
        }
        return menuItem
    }

    /// Gets the app to a working state, recording how far it got.
    ///
    /// Every step that cannot proceed is recorded rather than returned from silently: a launch that could
    /// not reach the daemon must not produce a window that looks exactly like a healthy one.
    private func runLaunchSequence() async {
        launchProgress.enter(.preparingDaemon)

        let availability = await daemonController.ensureDaemonUsable()
        guard availability.isUsable else {
            // Not the end of the road: the process monitor is already running, and every injection it
            // attempts makes the daemon usable first. This says where things stand right now.
            launchProgress.enter(.stopped(reason: availability.summary))
            return
        }

        // Pick up payloads still running from an earlier session before deciding anything else. Skipping
        // this makes a relaunched app report "not injected" while the payload is right there, and the
        // obvious response — injecting again — does nothing, because a mapped image cannot be loaded twice.
        // Before reconnecting, so the payloads picked up below are told in the same pass rather than
        // having to be revisited. The call records the setting whether or not anything is reachable yet.
        await dockAppsIconController.applyStoredSetting()

        launchProgress.enter(.reconnectingToPayloads)
        await injectionCoordinator.reconnectToResidentPayloads()

        if injectionCoordinator.isAutomaticInjectionEnabled {
            launchProgress.enter(.injecting)
            await injectionCoordinator.injectIntoRunningTargets()
        }

        launchProgress.enter(.ready)
    }
}
