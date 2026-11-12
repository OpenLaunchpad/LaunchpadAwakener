@testable import LaunchpadAwakenerPayloadCore
import LaunchpadAwakenerShared
import Testing

/// Telling the daemon apart from a target.
///
/// The memory-remap injection path loads the payload inside the daemon first, only to find its entry
/// symbol, and the payload must not start there. It tells by its host's executable name, which has to be
/// the name the build gives the daemon: `LaunchpadAwakenerDaemon` in every configuration, since the
/// Embed Daemon copy cannot follow a per-configuration name.
@Suite("Recognizing the injector process")
struct InjectorProcessTests {
    @Test("The daemon's executable is the injector")
    func daemonIsInjector() {
        #expect(PayloadEntry.isInjectorExecutable(named: "LaunchpadAwakenerDaemon"))
        #expect(PayloadEntry.isInjectorExecutable(named: InjectionServiceIdentity.daemonExecutableName))
    }

    @Test("A target, or anything named after the Mach service, is not")
    func targetIsNotInjector() {
        #expect(!PayloadEntry.isInjectorExecutable(named: "Dock"))
        #expect(!PayloadEntry.isInjectorExecutable(named: InjectionServiceIdentity.machServiceName))
    }
}
