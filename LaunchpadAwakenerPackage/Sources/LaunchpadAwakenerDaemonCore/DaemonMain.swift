import Foundation
import HelperCommunication
import HelperServer
import HelperService
import FilesServiceImplementation
import InjectionServiceImplementation
import LaunchpadAwakenerShared

/// Entry point for the privileged daemon.
///
/// The daemon owns no feature logic of its own. It exists because injecting into another process
/// needs `task_for_pid`, and placing a payload outside the app bundle needs root — both of which
/// the app cannot do. Everything it serves comes from `swift-helper-service`:
///
/// - `InjectionService` — the `dlopen` and `mach_vm_remap` injection paths.
/// - `FilesService` — privileged file placement, used to stage the payload.
///
/// `HelperServer` additionally mounts its own `MainService`, which answers the version query the
/// app uses to detect a stale daemon, plus a ping and the endpoint registry.
///
/// Add a service here only when it genuinely needs root. Anything the app can do itself belongs
/// in the app.
public enum DaemonMain {
    public static func run() async throws {
        let server = try await HelperServer(
            serverType: .machService(name: InjectionServiceIdentity.machServiceName),
            version: InjectionServiceIdentity.daemonVersion,
            services: [
                InjectionService(),
                FilesService(),
            ]
        )
        await server.activateAndRun()
    }
}
