import Foundation
import OSLog
import ObjCRuntimeToolbox
import LaunchpadAwakenerPayloadInterface
import LaunchpadAwakenerShared
import LaunchpadAwakenerSpringboardCore

/// Called by `LaunchpadAwakenerPayload/main.m` from both injection paths.
///
/// Exposed with `@_cdecl` so the Objective-C side can declare it as a plain C function; the Swift
/// symbol name would otherwise be mangled and unavailable to the constructor and the remap entry.
@_cdecl("LaunchpadAwakener_payload_initialize")
public func LaunchpadAwakener_payload_initialize() {
    PayloadEntry.start()
}

/// Everything the payload does inside the host process starts here.
public enum PayloadEntry {
    private static let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakener", category: "Payload")

    /// Guards against running twice.
    ///
    /// Both injection paths converge on this function, and a target that gets injected twice — a
    /// re-run of the app, a racing monitor — would otherwise install every hook a second time,
    /// chaining each replacement onto the previous one.
    private static let hasStarted = OSAllocatedUnfairLock(initialState: false)

    public static func start() {
        guard !isRunningInsideInjector else {
            // The remap injection path dlopens this payload inside the *daemon* first, purely to
            // resolve the entry symbol's address (MIMachInjectorRemap.m). That transient dlopen runs
            // our constructor in the wrong process. Bailing out here keeps the payload from starting
            // its real work inside the injector, and costs nothing on the dlopen path, where the
            // host is never the daemon.
            logger.debug("Loaded inside the injector process; skipping start")
            return
        }

        let isFirstStart = hasStarted.withLock { hasStartedValue -> Bool in
            guard !hasStartedValue else { return false }
            hasStartedValue = true
            return true
        }
        guard isFirstStart else {
            logger.info("Payload already started in this process; ignoring duplicate injection")
            return
        }

        logger.info(
            "Payload attached to \(ProcessInfo.processInfo.processName, privacy: .public) (\(ProcessInfo.processInfo.processIdentifier, privacy: .public))"
        )

        // Before any hook can call into the springboard.
        SpringboardHostSystem.bootstrap(host: DockSpringboardHost())
        let hookInstallation = installHooks()

        // Opened whatever became of the hooks: a payload that installed nothing is exactly what the
        // app's window most needs to hear about.
        Task {
            await PayloadPeer.shared.start(hookInstallation: hookInstallation)
        }
    }

    /// Whether this copy of the payload was loaded into the privileged daemon rather than a target.
    ///
    /// Identified by executable name: the daemon's executable is named by a constant the payload already
    /// shares with it, so the check needs no environment variable.
    private static var isRunningInsideInjector: Bool {
        let executableName = (CommandLine.arguments.first as NSString?)?.lastPathComponent
            ?? ProcessInfo.processInfo.processName
        return isInjectorExecutable(named: executableName)
    }

    /// Whether `executableName` is the daemon's. Not its Mach service name: the executable keeps one name
    /// in every configuration, while the service name differs between Debug and Release.
    static func isInjectorExecutable(named executableName: String) -> Bool {
        executableName == InjectionServiceIdentity.daemonExecutableName
    }

    /// Installs what the springboard can do without, as a batch of its own; returns how many hooks went in.
    /// A Dock whose method no longer matches keeps its own behaviour there and says so in the log.
    private static func installOptionalHooks() -> Int {
        let optionalHooks = PayloadHooks.optionalDescriptors()
        do {
            try RuntimeMethodHook.installAtomically(optionalHooks)
            logger.notice("Installed \(optionalHooks.count, privacy: .public) optional hook(s): the Dock stays on its display while the springboard shows")
            return optionalHooks.count
        } catch {
            logger.error("Optional hooks not installed: \(String(describing: error), privacy: .public); the Dock may move to another display while the springboard shows")
            return 0
        }
    }

    private static func installHooks() -> HookInstallation {
        let hooks = PayloadHooks.descriptors()

        guard !hooks.isEmpty else {
            logger.info("No hooks declared — payload is attached but inert")
            // `descriptors()` declares none for exactly one reason now, and has logged it.
            return .incompatibleDockMethods
        }

        do {
            try RuntimeMethodHook.installAtomically(hooks)
            // `notice` is the default level. Deliberately not info: info-level lines live only in the
            // memory buffer and are gone from the log store within hours, and this line — with the
            // method check above it — is exactly what gets looked up after a system upgrade.
            logger.notice("Installed \(hooks.count, privacy: .public) hook(s)")
            let optionalHookCount = installOptionalHooks()
            let missingVisibilityMembers = LiveDockVisibility.missingMembers()
            if missingVisibilityMembers.isEmpty {
                logger.info("The Dock's visibility controller matches: the Dock is kept on screen, and slides away for an open folder")
            } else {
                logger.error("The Dock's visibility controller lacks \(missingVisibilityMembers.joined(separator: ", "), privacy: .public); the Dock is left as it is")
            }
            let missingDropMethods = DockDropTarget.missingMethodNames
            if missingDropMethods.isEmpty {
                logger.info("The Dock's drag events match: an application dragged onto the Dock is kept there")
            } else {
                logger.error("The Dock lacks \(missingDropMethods.joined(separator: ", "), privacy: .public); nothing dragged onto the Dock is kept there")
            }
            #if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                MainActor.assumeIsolated {
                    DockDropTarget.logReachability()
                }
            }
            #endif
            LaunchpadServices.start()
            return .installed(hookCount: hooks.count + optionalHookCount)
        } catch {
            // Deliberately terminal-but-harmless: the payload stays loaded and does nothing.
            // Leaving the host untouched is always better than half-hooking it, and the log line
            // below is what tells you an operating system update moved the target out from under you.
            logger.error("Hook installation aborted, host left untouched: \(String(describing: error), privacy: .public)")
            return .failed(description: String(describing: error))
        }
    }
}
