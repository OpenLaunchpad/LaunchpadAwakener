import Foundation
import OSLog
import LaunchpadAwakenerHookKit
import LaunchpadAwakenerShared

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

        installHooks()
    }

    /// Whether this copy of the payload was loaded into the privileged daemon rather than a target.
    ///
    /// Identified by executable name: the daemon's product name is its Mach service name, which is
    /// exactly the constant the payload already shares with it. Deriving the check from that one
    /// constant is why this needs no environment variable and no second place to keep in sync.
    private static var isRunningInsideInjector: Bool {
        let executableName = (CommandLine.arguments.first as NSString?)?.lastPathComponent
            ?? ProcessInfo.processInfo.processName
        return executableName == InjectionServiceIdentity.machServiceName
    }

    private static func installHooks() {
        let hooks = PayloadHooks.descriptors()

        guard !hooks.isEmpty else {
            logger.info("No hooks declared — payload is attached but inert")
            return
        }

        do {
            try MethodHookInstaller.installAtomically(hooks)
            logger.info("Installed \(hooks.count, privacy: .public) hook(s)")
            LaunchpadServices.start()
        } catch {
            // Deliberately terminal-but-harmless: the payload stays loaded and does nothing.
            // Leaving the host untouched is always better than half-hooking it, and the log line
            // below is what tells you an operating system update moved the target out from under you.
            logger.error("Hook installation aborted, host left untouched: \(String(describing: error), privacy: .public)")
        }
    }
}
