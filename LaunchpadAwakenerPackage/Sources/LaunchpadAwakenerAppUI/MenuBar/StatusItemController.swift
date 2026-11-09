import AppKit
import AppKitPlus
import LaunchpadAwakenerAppCore

/// The menu bar icon and its menu.
///
/// The only way back into the app once its window is closed: with no Dock icon then, and no main menu
/// while the app is an accessory, this item is what keeps the app reachable at all. The menu is rebuilt
/// from the controllers' state each time it opens.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let daemonController: PrivilegedDaemonController
    private let injectionCoordinator: PayloadInjectionCoordinator
    private let killSwitchController: KillSwitchController
    private let launchProgress: ApplicationLaunchProgress
    private let showControlPanel: () -> Void
    private let showOrganizer: () -> Void

    init(
        daemonController: PrivilegedDaemonController,
        injectionCoordinator: PayloadInjectionCoordinator,
        killSwitchController: KillSwitchController,
        launchProgress: ApplicationLaunchProgress,
        showControlPanel: @escaping () -> Void,
        showOrganizer: @escaping () -> Void
    ) {
        self.daemonController = daemonController
        self.injectionCoordinator = injectionCoordinator
        self.killSwitchController = killSwitchController
        self.launchProgress = launchProgress
        self.showControlPanel = showControlPanel
        self.showOrganizer = showOrganizer
        super.init()

        let image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "LaunchpadAwakener")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "LaunchpadAwakener"
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let readiness = ControlPanelReadiness.evaluate(
            launchPhase: launchProgress.phase,
            daemonStatus: daemonController.registrationStatus,
            isKillSwitchEngaged: killSwitchController.isEngaged,
            isInjected: !injectionCoordinator.injectedProcessIdentifiers.isEmpty,
            residentPayloads: injectionCoordinator.residentPayloads
        )
        let statusTitleItem = NSMenuItem(title: ReadinessPresentation(readiness).title, action: nil, keyEquivalent: "")
        statusTitleItem.isEnabled = false

        let killSwitchItem = item("Open the System's Apps Instead") { [killSwitchController] in
            killSwitchController.setEngaged(!killSwitchController.isEngaged)
        }
        killSwitchItem.state = killSwitchController.isEngaged ? .on : .off

        let injectNowItem = item("Inject Now") { [injectionCoordinator] in
            Task { await injectionCoordinator.injectIntoRunningTargets() }
        }
        injectNowItem.isEnabled = daemonController.isEnabled && !injectionCoordinator.isBusy
        let restartDockItem = item("Restart Dock") { [injectionCoordinator] in
            injectionCoordinator.restartTargets()
        }
        restartDockItem.isEnabled = !injectionCoordinator.isBusy

        menu.items = [
            statusTitleItem,
            .separator(),
            item("Open LaunchpadAwakener", keyEquivalent: ",", perform: showControlPanel),
            item("Organize Launchpad…", perform: showOrganizer),
            .separator(),
            injectNowItem,
            restartDockItem,
            killSwitchItem,
            .separator(),
            item("Quit", keyEquivalent: "q") {
                NSApplication.shared.terminate(nil)
            },
        ]
    }

    private func item(_ title: String, keyEquivalent: String = "", perform: @escaping () -> Void) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: keyEquivalent)
        menuItem.primaryAction = NSAction { _ in
            perform()
        }
        return menuItem
    }
}
