import Foundation
import ObjCRuntimeToolbox
import OSToolbox

/// Deletes applications with the Dock's own uninstaller, the one macOS 15's Launchpad used.
///
/// `DockBar.environment.applicationUninstaller` is a `DockCore.SystemApplicationUninstaller`. 27.2 still
/// has it, callable through the Objective-C runtime, though nothing in that Dock calls it any more. It
/// hands the bundle to `uninstalld`, which the Dock is entitled to use: the application is deleted for
/// good — not moved to the Trash — with its preferences and containers, and a running copy is asked to
/// quit, then killed. Each method's signature is checked on the object's own class before the call; if
/// one does not match, deleting is unavailable and no close box shows.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockApplicationUninstaller")
@MainActor
enum DockApplicationUninstaller {
    /// `DockBar.environment.applicationUninstaller` with both methods as 27.2 has them; nil otherwise.
    ///
    /// Both objects are checked as the class they turn out to have, like the rest of what the environment
    /// hands out (see ``DockEnvironmentIconAppearanceAccess``).
    private static var uninstaller: DockApplicationUninstallingImplementation? {
        guard
            let environment = DockEnvironment.environmentObject,
            let uninstaller = DockEnvironmentUninstallerAccessImplementation(environment)?.applicationUninstaller
        else { return nil }
        return DockApplicationUninstallingImplementation(uninstaller)
    }

    /// Whether the Dock's uninstaller can be called at all.
    static var isAvailable: Bool {
        uninstaller != nil
    }

    /// Whether the uninstaller takes the application: one from the App Store, a web app, a Shortcuts
    /// droplet or a wrapped application (`uninstallabilityOfFileAtURL:` answering 1), which is when 15
    /// showed the close box.
    static func canUninstall(applicationAt bundleURL: URL) -> Bool {
        uninstaller?.uninstallabilityOfFileAtURL(bundleURL as NSURL) == 1
    }

    /// Deletes the application; `completion` runs on the main actor with whether it went.
    static func uninstall(applicationAt bundleURL: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let uninstaller else {
            completion(false)
            return
        }
        #log(.info, "Deleting \(bundleURL.path, privacy: .public)")
        // `@Sendable`, so the block is not taken for one isolated to the main actor: the answer comes on an
        // XPC or a global queue.
        uninstaller.uninstallBundleAtURL(bundleURL as NSURL) { @Sendable hasUninstalled in
            let hasSucceeded = hasUninstalled.boolValue
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(hasSucceeded)
                }
            }
        }
    }
}

/// `DockCore.Environment`, as far as deleting applications goes.
@RuntimeObjectProxy
protocol DockEnvironmentUninstallerAccess {
    /// A `DockCore.SystemApplicationUninstaller`.
    var applicationUninstaller: NSObject? { get }
}

/// `DockCore.SystemApplicationUninstaller`.
@RuntimeObjectProxy
protocol DockApplicationUninstalling {
    /// 1 when the uninstaller takes the application.
    func uninstallabilityOfFileAtURL(_ url: NSURL) -> Int32?
    /// The handler is called once, with whether the application was deleted.
    func uninstallBundleAtURL(_ url: NSURL, handler: @escaping @convention(block) (ObjCBool) -> Void)
}
