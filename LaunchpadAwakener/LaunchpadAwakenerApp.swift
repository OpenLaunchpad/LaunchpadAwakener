import SwiftUI
import LaunchpadAwakenerAppCore
import LaunchpadAwakenerShared

@main
struct LaunchpadAwakenerApp: App {
    @State private var daemonController: PrivilegedDaemonController
    @State private var injectionCoordinator: PayloadInjectionCoordinator

    /// The window is only needed to set the daemon up; once it is, launching — at login above all —
    /// stays in the menu bar.
    private let windowLaunchBehavior: SceneLaunchBehavior

    init() {
        let daemonController = PrivilegedDaemonController()
        let injectionCoordinator = PayloadInjectionCoordinator(
            daemonController: daemonController,
            targetMatchingRule: .executableName("Dock"),
            injectionMethod: .dynamicLibraryLoad
        )
        self.daemonController = daemonController
        self.injectionCoordinator = injectionCoordinator
        self.windowLaunchBehavior = daemonController.isEnabled ? .suppressed : .presented

        Task { @MainActor in
            await LaunchpadAwakenerApp.startAutomaticInjectionIfPreferred(
                daemonController: daemonController,
                injectionCoordinator: injectionCoordinator
            )
        }
    }

    var body: some Scene {
        Window("LaunchpadAwakener", id: "main") {
            MainView()
                .environment(daemonController)
                .environment(injectionCoordinator)
                .task {
                    // The daemon may have been approved since launch.
                    await LaunchpadAwakenerApp.startAutomaticInjectionIfPreferred(
                        daemonController: daemonController,
                        injectionCoordinator: injectionCoordinator
                    )
                }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(windowLaunchBehavior)

        MenuBarExtra("LaunchpadAwakener", systemImage: "square.grid.3x3") {
            MenuBarContent()
                .environment(daemonController)
                .environment(injectionCoordinator)
        }
    }

    /// Reconciles the daemon with this build, then — unless automatic injection was switched off —
    /// injects into the running Dock, follows it across restarts and stays a login item.
    ///
    /// A daemon left over from a previous build answers requests with the previous build's behaviour,
    /// which is why reconciling comes first. Safe to call more than once.
    @MainActor
    static func startAutomaticInjectionIfPreferred(
        daemonController: PrivilegedDaemonController,
        injectionCoordinator: PayloadInjectionCoordinator
    ) async {
        daemonController.refreshStatus()
        guard daemonController.isEnabled else { return }

        switch await daemonController.reconcileVersion() {
        case .upToDate, .reinstalled:
            guard injectionCoordinator.prefersAutomaticInjection else { return }
            injectionCoordinator.startAutomaticInjection()
            LaunchAtLogin.setEnabled(true)
            TextInputAgent.registerIfNeeded()
            await injectionCoordinator.injectIntoRunningTargets()
        case .staleButNotEnabled, .queryFailed, .reinstallFailed:
            break
        }
    }
}
