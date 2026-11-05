import SwiftUI
import LaunchpadAwakenerAppCore
import LaunchpadAwakenerShared

@main
struct LaunchpadAwakenerApp: App {
    @State private var daemonController: PrivilegedDaemonController
    @State private var injectionCoordinator: PayloadInjectionCoordinator

    init() {
        let daemonController = PrivilegedDaemonController()
        self.daemonController = daemonController
        self.injectionCoordinator = PayloadInjectionCoordinator(
            daemonController: daemonController,
            // Change this to the process you are injecting into. Prefer `.executablePath` over
            // `.executableName` once you know the exact path — a name can collide.
            targetMatchingRule: .executableName("Dock"),
            injectionMethod: .dynamicLibraryLoad
        )
    }

    var body: some Scene {
        Window("LaunchpadAwakener", id: "main") {
            MainView()
                .environment(daemonController)
                .environment(injectionCoordinator)
                .task {
                    // A daemon left over from a previous build answers requests with the previous
                    // build's behaviour. Reconciling on launch is what keeps "I rebuilt it but
                    // nothing changed" from eating an afternoon.
                    await reconcileDaemonOnLaunch()
                }
        }
        .windowResizability(.contentSize)

        MenuBarExtra("LaunchpadAwakener", systemImage: "syringe") {
            MenuBarContent()
                .environment(daemonController)
                .environment(injectionCoordinator)
        }
    }

    private func reconcileDaemonOnLaunch() async {
        daemonController.refreshStatus()
        guard daemonController.isEnabled else { return }

        switch await daemonController.reconcileVersion() {
        case .upToDate, .reinstalled:
            if injectionCoordinator.isAutomaticInjectionEnabled {
                await injectionCoordinator.injectIntoRunningTargets()
            }
        case .staleButNotEnabled, .queryFailed, .reinstallFailed:
            break
        }
    }
}
