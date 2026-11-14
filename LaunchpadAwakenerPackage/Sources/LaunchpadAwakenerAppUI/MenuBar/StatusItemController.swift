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
    private let dockAppsIconController: DockAppsIconController
    private let standaloneLaunchpadController: StandaloneLaunchpadController
    private let launchProgress: ApplicationLaunchProgress
    private let isInjectionBlockedBySystemIntegrityProtection: Bool
    private let showControlPanel: () -> Void
    private let showOrganizer: () -> Void

    init(
        daemonController: PrivilegedDaemonController,
        injectionCoordinator: PayloadInjectionCoordinator,
        killSwitchController: KillSwitchController,
        dockAppsIconController: DockAppsIconController,
        standaloneLaunchpadController: StandaloneLaunchpadController,
        launchProgress: ApplicationLaunchProgress,
        isInjectionBlockedBySystemIntegrityProtection: Bool,
        showControlPanel: @escaping () -> Void,
        showOrganizer: @escaping () -> Void
    ) {
        self.daemonController = daemonController
        self.injectionCoordinator = injectionCoordinator
        self.killSwitchController = killSwitchController
        self.dockAppsIconController = dockAppsIconController
        self.standaloneLaunchpadController = standaloneLaunchpadController
        self.launchProgress = launchProgress
        self.isInjectionBlockedBySystemIntegrityProtection = isInjectionBlockedBySystemIntegrityProtection
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
        if isInjectionBlockedBySystemIntegrityProtection {
            standaloneLaunchpadController.refreshStatus()
        }
        let readiness = ControlPanelReadiness.evaluate(
            isInjectionBlockedBySystemIntegrityProtection: isInjectionBlockedBySystemIntegrityProtection,
            isStandaloneLaunchpadInstalled: standaloneLaunchpadController.isInstalled,
            launchPhase: launchProgress.phase,
            daemonStatus: daemonController.registrationStatus,
            isKillSwitchEngaged: killSwitchController.isEngaged,
            isInjected: !injectionCoordinator.injectedProcessIdentifiers.isEmpty,
            residentPayloads: injectionCoordinator.residentPayloads
        )
        let statusTitleItem = NSMenuItem(title: ReadinessPresentation(readiness).title, action: nil, keyEquivalent: "")
        statusTitleItem.isEnabled = false

        // Nothing here injects while SIP is on; the menu offers the standalone app instead.
        guard !isInjectionBlockedBySystemIntegrityProtection else {
            let standaloneItem = if standaloneLaunchpadController.isInstalled {
                item("Open Launchpad") { [standaloneLaunchpadController] in
                    standaloneLaunchpadController.open()
                }
            } else {
                item("Install Launchpad") { [standaloneLaunchpadController] in
                    Task { await standaloneLaunchpadController.installAndOpen() }
                }
            }
            standaloneItem.isEnabled = standaloneLaunchpadController.isInstalled
                || (standaloneLaunchpadController.canInstall && !standaloneLaunchpadController.isInstalling)
            menu.items = [
                statusTitleItem,
                .separator(),
                item("Open LaunchpadAwakener", keyEquivalent: ",", perform: showControlPanel),
                standaloneItem,
                .separator(),
                item("Quit", keyEquivalent: "q") {
                    NSApplication.shared.terminate(nil)
                },
            ]
            return
        }

        let killSwitchItem = item("Open the System's Apps Instead") { [killSwitchController] in
            killSwitchController.setEngaged(!killSwitchController.isEngaged)
        }
        killSwitchItem.state = killSwitchController.isEngaged ? .on : .off

        let dockAppsIconItem = item("Use the Launchpad Icon for Apps") { [dockAppsIconController] in
            Task { await dockAppsIconController.setEnabled(!dockAppsIconController.isEnabled) }
        }
        dockAppsIconItem.state = dockAppsIconController.isEnabled ? .on : .off
        dockAppsIconItem.isEnabled = dockAppsIconController.isAvailable

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
            dockAppsIconItem,
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
